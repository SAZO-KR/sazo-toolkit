package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"golang.org/x/oauth2/google"
)

// ─────────────────────────────────────
// 정규표현식
var (
	japaneseRegex = regexp.MustCompile(`[\p{Hiragana}\p{Katakana}]`)
	koreanRegex   = regexp.MustCompile(`[\p{Hangul}]`)

	// 통화 금액 패턴 (긴 단위부터 매칭하여 부분 매칭 방지)
	koreanWonRegex   = regexp.MustCompile(`(\d[\d,.]*\s*)(만\s*원|천\s*원|억\s*원|조\s*원|원)`)
	japaneseYenRegex = regexp.MustCompile(`(\d[\d,.]*\s*)(万\s*円|千\s*円|億\s*円|兆\s*円|円)`)

	koreanLaughRegex   = regexp.MustCompile(`[ㅋ]{2,}|[ㅎ]{2,}`)
	japaneseLaughRegex = regexp.MustCompile(`w{3,}`)
)

// 통화 단위 매핑 (한→일)
var wonToJapanese = map[string]string{
	"만원": "万ウォン",
	"천원": "千ウォン",
	"억원": "億ウォン",
	"조원": "兆ウォン",
	"원":  "ウォン",
}

// 통화 단위 매핑 (일→한)
var yenToKorean = map[string]string{
	"万円": "만엔",
	"千円": "천엔",
	"億円": "억엔",
	"兆円": "조엔",
	"円":  "엔",
}

// ─────────────────────────────────────
// 설정
type Config struct {
	SlackBotToken      string          `json:"SLACK_BOT_TOKEN"`
	SlackSigningSecret string          `json:"SLACK_SIGNING_SECRET"`
	GoogleCloudProject string          `json:"GOOGLE_CLOUD_PROJECT_ID"`
	GoogleTranslateLoc string          `json:"GOOGLE_TRANSLATE_API_LOCATION"`
	GoogleCreds        json.RawMessage `json:"GOOGLE_CREDS"` // GCP 서비스 계정 JSON (중첩 객체)
}

// AWS Secrets Manager에서 설정 로드
func LoadConfigFromSecrets(ctx context.Context) (*Config, error) {
	secretName := os.Getenv("SECRET_NAME")
	if secretName == "" {
		// 로컬 개발용: 환경변수에서 직접 로드
		log.Println("[디버그] SECRET_NAME 없음, 환경변수에서 직접 로드")
		return &Config{
			SlackBotToken:      os.Getenv("SLACK_BOT_TOKEN"),
			SlackSigningSecret: os.Getenv("SLACK_SIGNING_SECRET"),
			GoogleCloudProject: os.Getenv("GOOGLE_CLOUD_PROJECT_ID"),
			GoogleTranslateLoc: os.Getenv("GOOGLE_TRANSLATE_API_LOCATION"),
			GoogleCreds:        json.RawMessage(os.Getenv("GOOGLE_CREDS")),
		}, nil
	}

	// AWS SDK 설정
	awsCfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("AWS 설정 로드 실패: %w", err)
	}

	// Secrets Manager 클라이언트
	client := secretsmanager.NewFromConfig(awsCfg)

	// 시크릿 가져오기
	result, err := client.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: &secretName,
	})
	if err != nil {
		return nil, fmt.Errorf("시크릿 로드 실패: %w", err)
	}

	// JSON 파싱
	var cfg Config
	if err := json.Unmarshal([]byte(*result.SecretString), &cfg); err != nil {
		return nil, fmt.Errorf("시크릿 파싱 실패: %w", err)
	}

	// 설정 로드 결과 로깅
	log.Printf("[디버그] Secrets Manager에서 설정 로드 완료 (secret=%s)", secretName)
	log.Printf("[디버그] SLACK_BOT_TOKEN: %d자", len(cfg.SlackBotToken))
	log.Printf("[디버그] SLACK_SIGNING_SECRET: %d자", len(cfg.SlackSigningSecret))
	log.Printf("[디버그] GOOGLE_CLOUD_PROJECT_ID: %s", cfg.GoogleCloudProject)
	log.Printf("[디버그] GOOGLE_TRANSLATE_API_LOCATION: %s", cfg.GoogleTranslateLoc)
	log.Printf("[디버그] GOOGLE_CREDS: %d바이트", len(cfg.GoogleCreds))
	if len(cfg.GoogleCreds) > 0 {
		log.Printf("[디버그] GOOGLE_CREDS 시작: %.50s...", string(cfg.GoogleCreds))
	} else {
		log.Println("[경고] GOOGLE_CREDS가 비어있음!")
	}

	return &cfg, nil
}

// ─────────────────────────────────────
// App 구조체
type App struct {
	cfg   *Config
	slack *slack.Client
}

func NewApp(cfg *Config) (*App, error) {
	if cfg.SlackBotToken == "" || cfg.SlackSigningSecret == "" {
		return nil, fmt.Errorf("Slack 설정 누락")
	}
	return &App{cfg: cfg, slack: slack.New(cfg.SlackBotToken)}, nil
}

// ─────────────────────────────────────
// UTF-8 헬퍼 함수
// isUTF8Continuation은 바이트가 UTF-8 continuation byte인지 확인합니다.
// UTF-8 continuation byte는 10xxxxxx 패턴 (0x80 ~ 0xBF)입니다.
func isUTF8Continuation(b byte) bool {
	return (b & 0xC0) == 0x80
}

// ─────────────────────────────────────
// 메시지 분할 (1600~1800byte 사이에서 개행 기준)
func splitByNewlineChunk(msg string, minB, maxB int) []string {
	data := []byte(msg)
	if len(data) <= maxB {
		return []string{msg}
	}

	var parts []string
	for len(data) > 0 {
		if len(data) <= maxB {
			parts = append(parts, string(data))
			break
		}
		cut := maxB
		for cut > minB && data[cut] != '\n' {
			cut--
		}
		if cut <= minB {
			cut = maxB
		}

		// UTF-8 문자 경계 조정: continuation byte를 만나면 문자 시작까지 후퇴
		// 한글/일본어 등 멀티바이트 문자가 중간에 잘리는 것을 방지
		for cut > 0 && isUTF8Continuation(data[cut]) {
			cut--
		}

		parts = append(parts, string(data[:cut]))
		data = data[cut:]
	}
	return parts
}

// ─────────────────────────────────────
// 통화 금액 보호 (번역 전처리/후처리)
func protectCurrency(text string, targetLang string) (string, []string) {
	var re *regexp.Regexp
	var unitMap map[string]string

	switch targetLang {
	case "ja":
		re = koreanWonRegex
		unitMap = wonToJapanese
	case "ko":
		re = japaneseYenRegex
		unitMap = yenToKorean
	default:
		return text, nil
	}

	var replacements []string
	result := re.ReplaceAllStringFunc(text, func(match string) string {
		subs := re.FindStringSubmatch(match)
		if len(subs) < 3 {
			return match
		}
		number := strings.TrimSpace(subs[1])
		unit := strings.ReplaceAll(subs[2], " ", "")

		targetUnit, ok := unitMap[unit]
		if !ok {
			return match
		}

		placeholder := fmt.Sprintf("__CUR%d__", len(replacements))
		replacements = append(replacements, number+targetUnit)
		return placeholder
	})

	return result, replacements
}

func restoreCurrency(text string, replacements []string) string {
	for i, replacement := range replacements {
		placeholder := fmt.Sprintf("__CUR%d__", i)
		text = strings.ReplaceAll(text, placeholder, replacement)
	}
	return text
}

// ─────────────────────────────────────
// 웃음 표현 보호 (ㅋㅋㅋ↔www 폭발 방지)
func protectLaughter(text string, targetLang string) (string, []string) {
	var replacements []string

	switch targetLang {
	case "ja":
		result := koreanLaughRegex.ReplaceAllStringFunc(text, func(match string) string {
			n := utf8.RuneCountInString(match)
			placeholder := fmt.Sprintf("__LAU%d__", len(replacements))
			replacements = append(replacements, strings.Repeat("w", n))
			return placeholder
		})
		return result, replacements

	case "ko":
		indices := japaneseLaughRegex.FindAllStringIndex(text, -1)
		if len(indices) == 0 {
			return text, nil
		}

		var buf strings.Builder
		prev := 0
		for _, loc := range indices {
			start, end := loc[0], loc[1]
			// www. → URL이므로 skip
			if end < len(text) && text[end] == '.' {
				buf.WriteString(text[prev:end])
				prev = end
				continue
			}
			buf.WriteString(text[prev:start])
			n := end - start
			placeholder := fmt.Sprintf("__LAU%d__", len(replacements))
			replacements = append(replacements, strings.Repeat("ㅋ", n))
			buf.WriteString(placeholder)
			prev = end
		}
		buf.WriteString(text[prev:])
		return buf.String(), replacements
	}

	return text, nil
}

func restoreLaughter(text string, replacements []string) string {
	for i, replacement := range replacements {
		placeholder := fmt.Sprintf("__LAU%d__", i)
		text = strings.ReplaceAll(text, placeholder, replacement)
	}
	return text
}

// ─────────────────────────────────────
// 언어 결정
// - 한국어+일본어 동시 존재: "" (skip)
// - 한국어만: "ja" (일본어로 번역)
// - 일본어만: "ko" (한국어로 번역)
// - 둘 다 없음: "" (skip)
func determineLang(s string) string {
	hasKorean := koreanRegex.MatchString(s)
	hasJapanese := japaneseRegex.MatchString(s)

	switch {
	case hasKorean && hasJapanese:
		return "" // 둘 다 있으면 skip
	case hasKorean:
		return "ja"
	case hasJapanese:
		return "ko"
	default:
		return "" // 둘 다 없으면 skip
	}
}

// ─────────────────────────────────────
// Google Translate API 호출
func (app *App) translateChunks(chunks []string, targetLang string) ([]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	proj := app.cfg.GoogleCloudProject
	loc := app.cfg.GoogleTranslateLoc
	if loc == "" {
		loc = "global"
	}

	// 서비스 계정 JSON으로 인증
	log.Printf("[디버그] 번역 요청 시작 (target=%s, chunks=%d개)", targetLang, len(chunks))
	log.Printf("[디버그] GoogleCreds 길이: %d바이트", len(app.cfg.GoogleCreds))

	var creds *google.Credentials
	var err error
	if len(app.cfg.GoogleCreds) > 0 {
		log.Println("[디버그] 서비스 계정 JSON으로 인증 시도")
		creds, err = google.CredentialsFromJSON(ctx, app.cfg.GoogleCreds, "https://www.googleapis.com/auth/cloud-translation")
		if err != nil {
			log.Printf("[에러] 서비스 계정 JSON 파싱 실패: %v", err)
			return nil, fmt.Errorf("GCP 인증 실패: %w", err)
		}
		log.Println("[디버그] 서비스 계정 JSON 인증 성공")
	} else {
		// 로컬 개발용: 기본 인증 (gcloud auth application-default login)
		log.Println("[디버그] 기본 인증(ADC) 시도 - GoogleCreds가 비어있음")
		creds, err = google.FindDefaultCredentials(ctx, "https://www.googleapis.com/auth/cloud-translation")
	}
	if err != nil {
		return nil, err
	}
	token, err := creds.TokenSource.Token()
	if err != nil {
		log.Printf("[에러] 토큰 획득 실패: %v", err)
		return nil, err
	}
	log.Println("[디버그] GCP 토큰 획득 성공")

	payload := map[string]interface{}{
		"contents":           chunks,
		"targetLanguageCode": targetLang,
		"mimeType":           "text/plain",
		"model":              fmt.Sprintf("projects/%s/locations/%s/models/general/translation-llm", proj, loc),
	}
	body, _ := json.Marshal(payload)

	url := fmt.Sprintf("https://translation.googleapis.com/v3/projects/%s/locations/%s:translateText", proj, loc)
	req, _ := http.NewRequestWithContext(ctx, "POST", url, bytes.NewBuffer(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token.AccessToken)

	log.Printf("[디버그] 번역 API 호출: %s", url)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("[에러] 번역 API 요청 실패: %v", err)
		return nil, err
	}
	defer resp.Body.Close()

	respB, _ := io.ReadAll(resp.Body)
	log.Printf("[디버그] 번역 API 응답: status=%d, body=%d바이트", resp.StatusCode, len(respB))
	if resp.StatusCode != http.StatusOK {
		log.Printf("[에러] 번역 API 실패: %s", string(respB))
		return nil, fmt.Errorf("번역 API 실패 (status=%d): %s", resp.StatusCode, respB)
	}

	var out struct {
		Translations []struct {
			TranslatedText string `json:"translatedText"`
		} `json:"translations"`
	}
	if err := json.Unmarshal(respB, &out); err != nil {
		return nil, err
	}

	// 번역 결과 개수 검증
	if len(out.Translations) != len(chunks) {
		log.Printf("[경고] 번역 청크 수 불일치: 요청=%d, 응답=%d", len(chunks), len(out.Translations))
		return nil, fmt.Errorf("번역 청크 수 불일치: 요청=%d, 응답=%d", len(chunks), len(out.Translations))
	}

	result := make([]string, len(out.Translations))
	for i, t := range out.Translations {
		result[i] = t.TranslatedText
	}
	return result, nil
}

// ─────────────────────────────────────
// 메시지 이벤트 처리
func (app *App) processMessage(ev *slackevents.MessageEvent) error {
	// 봇 메시지 무시
	if ev.BotID != "" {
		return nil
	}

	// 언어 판별
	lang := determineLang(ev.Text)
	if lang == "" {
		log.Printf("[스킵] 번역 불필요 (channel=%s, ts=%s)", ev.Channel, ev.TimeStamp)
		return nil
	}

	// 메시지 분할 (긴 메시지 대응)
	chunks := splitByNewlineChunk(ev.Text, 1600, 1800)

	// 번역 전처리: 통화 금액 + 웃음 표현 보호
	currencyRepls := make([][]string, len(chunks))
	laughterRepls := make([][]string, len(chunks))
	for i, chunk := range chunks {
		chunks[i], currencyRepls[i] = protectCurrency(chunk, lang)
		chunks[i], laughterRepls[i] = protectLaughter(chunks[i], lang)
	}

	// 번역
	translated, err := app.translateChunks(chunks, lang)
	if err != nil {
		return err
	}

	// 번역 후처리: 보호된 표현 복원
	for i := range translated {
		translated[i] = restoreLaughter(translated[i], laughterRepls[i])
		translated[i] = restoreCurrency(translated[i], currencyRepls[i])
	}

	// 결과 합치기
	text := strings.Join(translated, "\n\n")

	// 스레드 타임스탬프 결정
	threadTS := ev.ThreadTimeStamp
	if threadTS == "" {
		threadTS = ev.TimeStamp
	}

	// 슬랙에 전송
	_, _, err = app.slack.PostMessage(
		ev.Channel,
		slack.MsgOptionText(text, false),
		slack.MsgOptionTS(threadTS),
	)
	return err
}

// ─────────────────────────────────────
// Slack 서명 검증
func verifySlackSignature(headers map[string]string, body []byte, secret string) error {
	h := http.Header{}
	for k, v := range headers {
		h.Set(k, v)
	}

	sv, err := slack.NewSecretsVerifier(h, secret)
	if err != nil {
		return err
	}
	if _, err := sv.Write(body); err != nil {
		return err
	}
	return sv.Ensure()
}

// ─────────────────────────────────────
// Lambda 핸들러
func (app *App) handler(ctx context.Context, event events.LambdaFunctionURLRequest) (events.LambdaFunctionURLResponse, error) {
	// Slack 재시도 요청 무시 (중복 방지)
	if event.Headers["x-slack-retry-num"] != "" {
		log.Printf("[스킵] Slack 재시도 요청 무시 (retry=%s)", event.Headers["x-slack-retry-num"])
		return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
	}

	body := []byte(event.Body)

	// 서명 검증
	if err := verifySlackSignature(event.Headers, body, app.cfg.SlackSigningSecret); err != nil {
		log.Printf("[에러] 서명 검증 실패: %v", err)
		return events.LambdaFunctionURLResponse{StatusCode: 401}, nil
	}

	// 이벤트 파싱
	evt, err := slackevents.ParseEvent(json.RawMessage(body), slackevents.OptionNoVerifyToken())
	if err != nil {
		log.Printf("[에러] 이벤트 파싱 실패: %v", err)
		return events.LambdaFunctionURLResponse{StatusCode: 400}, nil
	}

	// URL 검증 (Slack 앱 설정 시 필요)
	if evt.Type == slackevents.URLVerification {
		var ch slackevents.ChallengeResponse
		json.Unmarshal(body, &ch)
		return events.LambdaFunctionURLResponse{
			StatusCode: 200,
			Headers:    map[string]string{"Content-Type": "text/plain"},
			Body:       ch.Challenge,
		}, nil
	}

	// 콜백 이벤트 처리
	if evt.Type == slackevents.CallbackEvent {
		if ev, ok := evt.InnerEvent.Data.(*slackevents.MessageEvent); ok {
			if err := app.processMessage(ev); err != nil {
				log.Printf("[에러] 메시지 처리 실패: %v", err)
			}
		}
	}

	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// 전역 앱 인스턴스 (Lambda cold start 최적화)
var app *App

func init() {
	ctx := context.Background()
	cfg, err := LoadConfigFromSecrets(ctx)
	if err != nil {
		log.Fatalf("[치명적] 설정 로드 실패: %v", err)
	}
	app, err = NewApp(cfg)
	if err != nil {
		log.Fatalf("[치명적] 앱 초기화 실패: %v", err)
	}
}

func main() {
	lambda.Start(app.handler)
}

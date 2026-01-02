package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/url"
	"os"
	"strings"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/slack-go/slack"
)

// ─────────────────────────────────────
// 상수
const (
	TargetChannelID = "C09SQ9N05MZ" // 익명 메시지가 게시될 채널

	// Callback IDs
	CallbackNewPost      = "bamboo_new_post"
	CallbackNewThread    = "bamboo_new_thread"
	ActionReplyButton    = "bamboo_reply"
	BlockIDMessage       = "message_block"
	BlockIDName          = "name_block"
	BlockIDConfirm       = "confirm_block"
	ActionIDMessage      = "message_input"
	ActionIDName         = "name_input"
	ActionIDConfirm      = "confirm_checkbox"
)

// ─────────────────────────────────────
// 설정
type Config struct {
	SlackBotToken      string `json:"SLACK_BOT_TOKEN"`
	SlackSigningSecret string `json:"SLACK_SIGNING_SECRET"`
}

func LoadConfigFromSecrets(ctx context.Context) (*Config, error) {
	secretName := os.Getenv("SECRET_NAME")
	if secretName == "" {
		log.Println("[디버그] SECRET_NAME 없음, 환경변수에서 직접 로드")
		return &Config{
			SlackBotToken:      os.Getenv("SLACK_BOT_TOKEN"),
			SlackSigningSecret: os.Getenv("SLACK_SIGNING_SECRET"),
		}, nil
	}

	awsCfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("AWS 설정 로드 실패: %w", err)
	}

	client := secretsmanager.NewFromConfig(awsCfg)
	result, err := client.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: &secretName,
	})
	if err != nil {
		return nil, fmt.Errorf("시크릿 로드 실패: %w", err)
	}

	var cfg Config
	if err := json.Unmarshal([]byte(*result.SecretString), &cfg); err != nil {
		return nil, fmt.Errorf("시크릿 파싱 실패: %w", err)
	}

	log.Printf("[디버그] Secrets Manager에서 설정 로드 완료 (secret=%s)", secretName)
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
// 모달 생성: 새 글 작성
func buildNewPostModal() slack.ModalViewRequest {
	return slack.ModalViewRequest{
		Type:            slack.ViewType("modal"),
		CallbackID:      CallbackNewPost,
		Title:           slack.NewTextBlockObject("plain_text", "🎋 대나무숲", false, false),
		Submit:          slack.NewTextBlockObject("plain_text", "게시하기", false, false),
		Close:           slack.NewTextBlockObject("plain_text", "취소", false, false),
		Blocks: slack.Blocks{
			BlockSet: []slack.Block{
				// 메시지 입력 (필수)
				slack.NewInputBlock(
					BlockIDMessage,
					slack.NewTextBlockObject("plain_text", "익명 메시지", false, false),
					slack.NewTextBlockObject("plain_text", "하고 싶은 말을 적어주세요", false, false),
					slack.NewPlainTextInputBlockElement(
						slack.NewTextBlockObject("plain_text", "익명으로 전달하고 싶은 이야기를 적어주세요...", false, false),
						ActionIDMessage,
					).WithMultiline(true),
				),
				// 닉네임 입력 (선택)
				slack.NewInputBlock(
					BlockIDName,
					slack.NewTextBlockObject("plain_text", "닉네임 (선택사항)", false, false),
					slack.NewTextBlockObject("plain_text", "비워두면 '익명'으로 표시됩니다", false, false),
					slack.NewPlainTextInputBlockElement(
						slack.NewTextBlockObject("plain_text", "예: 3년차 개발자, 신입사원 등", false, false),
						ActionIDName,
					),
				).WithOptional(true),
				// 구분선
				slack.NewDividerBlock(),
				// 안내 문구
				slack.NewSectionBlock(
					slack.NewTextBlockObject("mrkdwn", "⚠️ *주의사항*\n• 게시된 메시지는 수정하거나 삭제할 수 없습니다\n• 타인을 비방하거나 불쾌감을 주는 내용은 삼가주세요", false, false),
					nil, nil,
				),
				// 확인 체크박스 (필수)
				slack.NewInputBlock(
					BlockIDConfirm,
					slack.NewTextBlockObject("plain_text", "확인", false, false),
					nil,
					slack.NewCheckboxGroupsBlockElement(
						ActionIDConfirm,
						slack.NewOptionBlockObject(
							"confirmed",
							slack.NewTextBlockObject("mrkdwn", "*위 내용을 확인했으며, 게시 후 수정/삭제가 불가능함을 이해합니다*", false, false),
							nil,
						),
					),
				),
			},
		},
	}
}

// ─────────────────────────────────────
// 모달 생성: 스레드 답글
func buildThreadModal(channelID, threadTS string) slack.ModalViewRequest {
	// private_metadata에 채널과 스레드 정보 저장
	metadata := fmt.Sprintf("%s|%s", channelID, threadTS)

	return slack.ModalViewRequest{
		Type:            slack.ViewType("modal"),
		CallbackID:      CallbackNewThread,
		PrivateMetadata: metadata,
		Title:           slack.NewTextBlockObject("plain_text", "🎋 익명 답글", false, false),
		Submit:          slack.NewTextBlockObject("plain_text", "답글 달기", false, false),
		Close:           slack.NewTextBlockObject("plain_text", "취소", false, false),
		Blocks: slack.Blocks{
			BlockSet: []slack.Block{
				// 메시지 입력 (필수)
				slack.NewInputBlock(
					BlockIDMessage,
					slack.NewTextBlockObject("plain_text", "익명 답글", false, false),
					slack.NewTextBlockObject("plain_text", "스레드에 익명으로 답글을 남깁니다", false, false),
					slack.NewPlainTextInputBlockElement(
						slack.NewTextBlockObject("plain_text", "익명으로 전달하고 싶은 답글을 적어주세요...", false, false),
						ActionIDMessage,
					).WithMultiline(true),
				),
				// 닉네임 입력 (선택)
				slack.NewInputBlock(
					BlockIDName,
					slack.NewTextBlockObject("plain_text", "닉네임 (선택사항)", false, false),
					slack.NewTextBlockObject("plain_text", "비워두면 '익명'으로 표시됩니다", false, false),
					slack.NewPlainTextInputBlockElement(
						slack.NewTextBlockObject("plain_text", "예: 3년차 개발자, 신입사원 등", false, false),
						ActionIDName,
					),
				).WithOptional(true),
				// 구분선
				slack.NewDividerBlock(),
				// 확인 체크박스 (필수)
				slack.NewInputBlock(
					BlockIDConfirm,
					slack.NewTextBlockObject("plain_text", "확인", false, false),
					nil,
					slack.NewCheckboxGroupsBlockElement(
						ActionIDConfirm,
						slack.NewOptionBlockObject(
							"confirmed",
							slack.NewTextBlockObject("mrkdwn", "*게시 후 수정/삭제가 불가능함을 이해합니다*", false, false),
							nil,
						),
					),
				),
			},
		},
	}
}

// ─────────────────────────────────────
// 메시지 블록 생성 (답글 버튼 포함)
func buildMessageBlocks(message, nickname string) []slack.Block {
	displayName := nickname
	if displayName == "" {
		displayName = "익명"
	}

	return []slack.Block{
		// 헤더 (닉네임)
		slack.NewContextBlock(
			"",
			slack.NewTextBlockObject("mrkdwn", fmt.Sprintf("🎋 *%s*", displayName), false, false),
		),
		// 메시지 본문
		slack.NewSectionBlock(
			slack.NewTextBlockObject("mrkdwn", message, false, false),
			nil, nil,
		),
		// 구분선
		slack.NewDividerBlock(),
		// 답글 버튼
		slack.NewActionBlock(
			"",
			slack.NewButtonBlockElement(
				ActionReplyButton,
				"reply",
				slack.NewTextBlockObject("plain_text", "💬 익명 답글 달기", false, false),
			),
		),
	}
}

// ─────────────────────────────────────
// Slash Command 처리
func (app *App) handleSlashCommand(body string) (events.LambdaFunctionURLResponse, error) {
	values, err := url.ParseQuery(body)
	if err != nil {
		return events.LambdaFunctionURLResponse{StatusCode: 400}, err
	}

	triggerID := values.Get("trigger_id")
	if triggerID == "" {
		return events.LambdaFunctionURLResponse{StatusCode: 400}, fmt.Errorf("trigger_id 없음")
	}

	// 모달 열기
	modal := buildNewPostModal()
	_, err = app.slack.OpenView(triggerID, modal)
	if err != nil {
		log.Printf("[에러] 모달 열기 실패: %v", err)
		return events.LambdaFunctionURLResponse{StatusCode: 500}, err
	}

	log.Println("[성공] /bamboo 모달 열기 완료")
	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// Interactive Component 처리
func (app *App) handleInteraction(body string) (events.LambdaFunctionURLResponse, error) {
	values, err := url.ParseQuery(body)
	if err != nil {
		return events.LambdaFunctionURLResponse{StatusCode: 400}, err
	}

	payloadStr := values.Get("payload")
	if payloadStr == "" {
		return events.LambdaFunctionURLResponse{StatusCode: 400}, fmt.Errorf("payload 없음")
	}

	var payload slack.InteractionCallback
	if err := json.Unmarshal([]byte(payloadStr), &payload); err != nil {
		log.Printf("[에러] payload 파싱 실패: %v", err)
		return events.LambdaFunctionURLResponse{StatusCode: 400}, err
	}

	switch payload.Type {
	case slack.InteractionTypeViewSubmission:
		return app.handleViewSubmission(payload)
	case slack.InteractionTypeBlockActions:
		return app.handleBlockAction(payload)
	default:
		log.Printf("[무시] 처리하지 않는 interaction type: %s", payload.Type)
		return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
	}
}

// ─────────────────────────────────────
// View Submission 처리
func (app *App) handleViewSubmission(payload slack.InteractionCallback) (events.LambdaFunctionURLResponse, error) {
	callbackID := payload.View.CallbackID
	values := payload.View.State.Values

	// 메시지 추출
	message := ""
	if msgBlock, ok := values[BlockIDMessage]; ok {
		if msgInput, ok := msgBlock[ActionIDMessage]; ok {
			message = msgInput.Value
		}
	}
	if message == "" {
		return respondWithError("메시지를 입력해주세요")
	}

	// 닉네임 추출
	nickname := ""
	if nameBlock, ok := values[BlockIDName]; ok {
		if nameInput, ok := nameBlock[ActionIDName]; ok {
			nickname = nameInput.Value
		}
	}

	// 체크박스 확인
	confirmed := false
	if confirmBlock, ok := values[BlockIDConfirm]; ok {
		if confirmInput, ok := confirmBlock[ActionIDConfirm]; ok {
			confirmed = len(confirmInput.SelectedOptions) > 0
		}
	}
	if !confirmed {
		return respondWithError("확인 체크박스를 선택해주세요")
	}

	switch callbackID {
	case CallbackNewPost:
		return app.postNewMessage(message, nickname)
	case CallbackNewThread:
		return app.postThreadReply(payload.View.PrivateMetadata, message, nickname)
	default:
		return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
	}
}

// ─────────────────────────────────────
// 새 메시지 게시
func (app *App) postNewMessage(message, nickname string) (events.LambdaFunctionURLResponse, error) {
	blocks := buildMessageBlocks(message, nickname)

	_, _, err := app.slack.PostMessage(
		TargetChannelID,
		slack.MsgOptionBlocks(blocks...),
	)
	if err != nil {
		log.Printf("[에러] 메시지 게시 실패: %v", err)
		return respondWithError("메시지 게시에 실패했습니다. 잠시 후 다시 시도해주세요.")
	}

	log.Printf("[성공] 익명 메시지 게시 완료 (nickname=%s)", nickname)
	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// 스레드 답글 게시
func (app *App) postThreadReply(metadata, message, nickname string) (events.LambdaFunctionURLResponse, error) {
	parts := strings.Split(metadata, "|")
	if len(parts) != 2 {
		return respondWithError("잘못된 요청입니다")
	}
	channelID, threadTS := parts[0], parts[1]

	blocks := buildMessageBlocks(message, nickname)

	_, _, err := app.slack.PostMessage(
		channelID,
		slack.MsgOptionBlocks(blocks...),
		slack.MsgOptionTS(threadTS),
	)
	if err != nil {
		log.Printf("[에러] 스레드 답글 게시 실패: %v", err)
		return respondWithError("답글 게시에 실패했습니다. 잠시 후 다시 시도해주세요.")
	}

	log.Printf("[성공] 익명 스레드 답글 게시 완료 (channel=%s, thread=%s)", channelID, threadTS)
	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// Block Action 처리 (버튼 클릭)
func (app *App) handleBlockAction(payload slack.InteractionCallback) (events.LambdaFunctionURLResponse, error) {
	for _, action := range payload.ActionCallback.BlockActions {
		if action.ActionID == ActionReplyButton {
			// 스레드 답글 모달 열기
			channelID := payload.Channel.ID
			// 스레드 타임스탬프 결정 (이미 스레드인 경우 원본 스레드 사용)
			threadTS := payload.Message.ThreadTimestamp
			if threadTS == "" {
				threadTS = payload.Message.Timestamp
			}

			modal := buildThreadModal(channelID, threadTS)
			_, err := app.slack.OpenView(payload.TriggerID, modal)
			if err != nil {
				log.Printf("[에러] 스레드 모달 열기 실패: %v", err)
				return events.LambdaFunctionURLResponse{StatusCode: 500}, err
			}

			log.Printf("[성공] 스레드 답글 모달 열기 완료 (channel=%s, thread=%s)", channelID, threadTS)
		}
	}

	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// 에러 응답 (모달에 에러 표시)
func respondWithError(message string) (events.LambdaFunctionURLResponse, error) {
	response := map[string]interface{}{
		"response_action": "errors",
		"errors": map[string]string{
			BlockIDMessage: message,
		},
	}
	body, _ := json.Marshal(response)
	return events.LambdaFunctionURLResponse{
		StatusCode: 200,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       string(body),
	}, nil
}

// ─────────────────────────────────────
// Slack 서명 검증
func verifySlackSignature(headers map[string]string, body []byte, secret string) error {
	// 헤더 이름 정규화 (소문자로 변환)
	normalizedHeaders := make(map[string]string)
	for k, v := range headers {
		normalizedHeaders[strings.ToLower(k)] = v
	}

	timestamp := normalizedHeaders["x-slack-request-timestamp"]
	signature := normalizedHeaders["x-slack-signature"]

	if timestamp == "" || signature == "" {
		return fmt.Errorf("Slack 서명 헤더 누락")
	}

	sv, err := slack.NewSecretsVerifier(mapToHeader(headers), secret)
	if err != nil {
		return err
	}
	if _, err := sv.Write(body); err != nil {
		return err
	}
	return sv.Ensure()
}

func mapToHeader(headers map[string]string) map[string][]string {
	h := make(map[string][]string)
	for k, v := range headers {
		h[k] = []string{v}
	}
	return h
}

// ─────────────────────────────────────
// Lambda 핸들러
func (app *App) handler(ctx context.Context, event events.LambdaFunctionURLRequest) (events.LambdaFunctionURLResponse, error) {
	body := []byte(event.Body)

	// 서명 검증
	if err := verifySlackSignature(event.Headers, body, app.cfg.SlackSigningSecret); err != nil {
		log.Printf("[에러] 서명 검증 실패: %v", err)
		return events.LambdaFunctionURLResponse{StatusCode: 401}, nil
	}

	// Content-Type 확인
	contentType := event.Headers["content-type"]
	if contentType == "" {
		contentType = event.Headers["Content-Type"]
	}

	// Slash Command인지 Interactive Component인지 구분
	if strings.Contains(event.Body, "command=%2Fbamboo") || strings.Contains(event.Body, "command=/bamboo") {
		log.Println("[요청] Slash Command 처리")
		return app.handleSlashCommand(event.Body)
	}

	if strings.Contains(event.Body, "payload=") {
		log.Println("[요청] Interactive Component 처리")
		return app.handleInteraction(event.Body)
	}

	log.Printf("[무시] 알 수 없는 요청 타입: %s", event.Body[:min(100, len(event.Body))])
	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// 전역 앱 인스턴스
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

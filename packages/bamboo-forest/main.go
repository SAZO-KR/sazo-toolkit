package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/slack-go/slack"
	"golang.org/x/oauth2/google"
	"google.golang.org/api/option"
	"google.golang.org/api/sheets/v4"
)

// ─────────────────────────────────────
// 상수
const (
	TargetChannelID = "C09SQ9N05MZ" // 익명 메시지가 게시될 채널

	// Callback IDs
	CallbackNewPost   = "bamboo_new_post"
	CallbackNewThread = "bamboo_new_thread"

	// Block IDs
	BlockIDMessage  = "message_block"
	BlockIDName     = "name_block"
	BlockIDMention  = "mention_block"
	BlockIDCategory = "category_block"
	BlockIDUrgency  = "urgency_block"
	BlockIDConfirm  = "confirm_block"

	// Action IDs
	ActionIDMessage  = "message_input"
	ActionIDName     = "name_input"
	ActionIDMention  = "mention_input"
	ActionIDCategory = "category_input"
	ActionIDUrgency  = "urgency_input"
	ActionIDConfirm  = "confirm_checkbox"

	// Button Action IDs
	ActionReplyButton    = "bamboo_reply"
	ActionCompleteButton = "bamboo_complete"

	// Emoji Reaction Action IDs
	ActionEmojiThumbsUp   = "bamboo_emoji_thumbsup"
	ActionEmojiThumbsDown = "bamboo_emoji_thumbsdown"
	ActionEmojiHug        = "bamboo_emoji_hug"
	ActionEmojiFlex       = "bamboo_emoji_flex"
)

// ─────────────────────────────────────
// 설정
type Config struct {
	SlackBotToken      string `json:"SLACK_BOT_TOKEN"`
	SlackSigningSecret string `json:"SLACK_SIGNING_SECRET"`
	// GCP 설정 (익명 이모지 리액션용)
	GoogleCloudProjectID string `json:"GOOGLE_CLOUD_PROJECT_ID"`
	GoogleCreds          string `json:"GOOGLE_CREDS"`
	SheetsID             string `json:"SHEETS_ID"`
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
	cfg    *Config
	slack  *slack.Client
	sheets *sheets.Service
}

func NewApp(ctx context.Context, cfg *Config) (*App, error) {
	if cfg.SlackBotToken == "" || cfg.SlackSigningSecret == "" {
		return nil, fmt.Errorf("Slack 설정 누락")
	}

	app := &App{
		cfg:   cfg,
		slack: slack.New(cfg.SlackBotToken),
	}

	// Google Sheets 클라이언트 초기화 (설정이 있는 경우에만)
	if cfg.GoogleCreds != "" && cfg.SheetsID != "" && cfg.SheetsID != "PLACEHOLDER" {
		creds, err := google.CredentialsFromJSON(ctx, []byte(cfg.GoogleCreds), sheets.SpreadsheetsScope)
		if err != nil {
			log.Printf("[경고] Google 인증 실패, 이모지 기능 비활성화: %v", err)
		} else {
			sheetsService, err := sheets.NewService(ctx, option.WithCredentials(creds))
			if err != nil {
				log.Printf("[경고] Sheets 서비스 생성 실패, 이모지 기능 비활성화: %v", err)
			} else {
				app.sheets = sheetsService
				log.Printf("[성공] Google Sheets 클라이언트 초기화 완료 (sheetsID=%s)", cfg.SheetsID)
			}
		}
	} else {
		log.Println("[정보] Google Sheets 설정 없음, 이모지 기능 비활성화")
	}

	return app, nil
}

// ─────────────────────────────────────
// 카테고리/긴급도 옵션
var categoryOptions = []*slack.OptionBlockObject{
	slack.NewOptionBlockObject("suggestion", slack.NewTextBlockObject("plain_text", "💡 건의사항", false, false), nil),
	slack.NewOptionBlockObject("question", slack.NewTextBlockObject("plain_text", "❓ 질문", false, false), nil),
	slack.NewOptionBlockObject("praise", slack.NewTextBlockObject("plain_text", "👏 칭찬", false, false), nil),
	slack.NewOptionBlockObject("concern", slack.NewTextBlockObject("plain_text", "💭 고민", false, false), nil),
	slack.NewOptionBlockObject("other", slack.NewTextBlockObject("plain_text", "📝 기타", false, false), nil),
}

var urgencyOptions = []*slack.OptionBlockObject{
	slack.NewOptionBlockObject("urgent", slack.NewTextBlockObject("plain_text", "🔴 긴급", false, false), nil),
	slack.NewOptionBlockObject("normal", slack.NewTextBlockObject("plain_text", "🟡 보통", false, false), nil),
	slack.NewOptionBlockObject("low", slack.NewTextBlockObject("plain_text", "🟢 여유", false, false), nil),
}

var categoryLabels = map[string]string{
	"suggestion": "💡 건의사항",
	"question":   "❓ 질문",
	"praise":     "👏 칭찬",
	"concern":    "💭 고민",
	"other":      "📝 기타",
}

var urgencyLabels = map[string]string{
	"urgent": "🔴 긴급",
	"normal": "🟡 보통",
	"low":    "🟢 여유",
}

// ─────────────────────────────────────
// 모달 생성: 새 글 작성
func buildNewPostModal() slack.ModalViewRequest {
	return slack.ModalViewRequest{
		Type:       slack.ViewType("modal"),
		CallbackID: CallbackNewPost,
		Title:      slack.NewTextBlockObject("plain_text", "🎋 대나무숲", false, false),
		Submit:     slack.NewTextBlockObject("plain_text", "게시하기", false, false),
		Close:      slack.NewTextBlockObject("plain_text", "취소", false, false),
		Blocks: slack.Blocks{
			BlockSet: []slack.Block{
				// 카테고리 선택 (필수)
				slack.NewInputBlock(
					BlockIDCategory,
					slack.NewTextBlockObject("plain_text", "카테고리", false, false),
					slack.NewTextBlockObject("plain_text", "메시지 종류를 선택하세요", false, false),
					slack.NewOptionsSelectBlockElement(
						"static_select",
						slack.NewTextBlockObject("plain_text", "카테고리 선택...", false, false),
						ActionIDCategory,
						categoryOptions...,
					),
				),
				// 긴급도 선택 (선택)
				slack.NewInputBlock(
					BlockIDUrgency,
					slack.NewTextBlockObject("plain_text", "긴급도 (선택사항)", false, false),
					slack.NewTextBlockObject("plain_text", "기본값: 보통", false, false),
					slack.NewOptionsSelectBlockElement(
						"static_select",
						slack.NewTextBlockObject("plain_text", "긴급도 선택...", false, false),
						ActionIDUrgency,
						urgencyOptions...,
					),
				).WithOptional(true),
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
				// 멘션할 사람 (선택)
				slack.NewInputBlock(
					BlockIDMention,
					slack.NewTextBlockObject("plain_text", "멘션할 사람 (선택사항)", false, false),
					slack.NewTextBlockObject("plain_text", "메시지에서 언급할 사람을 선택하세요", false, false),
					slack.NewOptionsMultiSelectBlockElement(
						"multi_users_select",
						slack.NewTextBlockObject("plain_text", "사람 선택...", false, false),
						ActionIDMention,
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
				// 멘션할 사람 (선택)
				slack.NewInputBlock(
					BlockIDMention,
					slack.NewTextBlockObject("plain_text", "멘션할 사람 (선택사항)", false, false),
					slack.NewTextBlockObject("plain_text", "메시지에서 언급할 사람을 선택하세요", false, false),
					slack.NewOptionsMultiSelectBlockElement(
						"multi_users_select",
						slack.NewTextBlockObject("plain_text", "사람 선택...", false, false),
						ActionIDMention,
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
// 새 글 메시지 블록 생성 (카테고리/긴급도/처리완료 버튼 포함)
func buildNewPostBlocks(message, nickname string, mentions []string, category, urgency string) []slack.Block {
	displayName := nickname
	if displayName == "" {
		displayName = "익명"
	}

	// 멘션 문자열 생성
	mentionText := ""
	if len(mentions) > 0 {
		var mentionParts []string
		for _, userID := range mentions {
			mentionParts = append(mentionParts, fmt.Sprintf("<@%s>", userID))
		}
		mentionText = strings.Join(mentionParts, " ") + "\n\n"
	}

	// 카테고리/긴급도 라벨
	categoryLabel := categoryLabels[category]
	urgencyLabel := urgencyLabels[urgency]

	return []slack.Block{
		// 헤더 (닉네임 + 카테고리 + 긴급도)
		slack.NewContextBlock(
			"",
			slack.NewTextBlockObject("mrkdwn", fmt.Sprintf("🎋 *%s* │ %s │ %s", displayName, categoryLabel, urgencyLabel), false, false),
		),
		// 메시지 본문
		slack.NewSectionBlock(
			slack.NewTextBlockObject("mrkdwn", mentionText+message, false, false),
			nil, nil,
		),
		// 이모지 리액션 카운트 (초기값 0)
		slack.NewContextBlock(
			"emoji_counts",
			slack.NewTextBlockObject("mrkdwn", "👍 0 │ 👎 0 │ 🤗 0 │ 💪 0", false, false),
		),
		// 이모지 버튼들
		slack.NewActionBlock(
			"emoji_actions",
			slack.NewButtonBlockElement(
				ActionEmojiThumbsUp,
				"thumbsup",
				slack.NewTextBlockObject("plain_text", "👍", true, false),
			),
			slack.NewButtonBlockElement(
				ActionEmojiThumbsDown,
				"thumbsdown",
				slack.NewTextBlockObject("plain_text", "👎", true, false),
			),
			slack.NewButtonBlockElement(
				ActionEmojiHug,
				"hug",
				slack.NewTextBlockObject("plain_text", "🤗", true, false),
			),
			slack.NewButtonBlockElement(
				ActionEmojiFlex,
				"flex",
				slack.NewTextBlockObject("plain_text", "💪", true, false),
			),
		),
		// 구분선
		slack.NewDividerBlock(),
		// 버튼들 (답글 + 처리완료)
		slack.NewActionBlock(
			"",
			slack.NewButtonBlockElement(
				ActionReplyButton,
				"reply",
				slack.NewTextBlockObject("plain_text", "💬 익명 답글 달기", false, false),
			),
			slack.NewButtonBlockElement(
				ActionCompleteButton,
				"complete",
				slack.NewTextBlockObject("plain_text", "✅ 처리 완료", false, false),
			),
		),
	}
}

// ─────────────────────────────────────
// 스레드 답글 메시지 블록 생성
func buildThreadReplyBlocks(message, nickname string, mentions []string) []slack.Block {
	displayName := nickname
	if displayName == "" {
		displayName = "익명"
	}

	// 멘션 문자열 생성
	mentionText := ""
	if len(mentions) > 0 {
		var mentionParts []string
		for _, userID := range mentions {
			mentionParts = append(mentionParts, fmt.Sprintf("<@%s>", userID))
		}
		mentionText = strings.Join(mentionParts, " ") + "\n\n"
	}

	return []slack.Block{
		// 헤더 (닉네임)
		slack.NewContextBlock(
			"",
			slack.NewTextBlockObject("mrkdwn", fmt.Sprintf("🎋 *%s*", displayName), false, false),
		),
		// 메시지 본문
		slack.NewSectionBlock(
			slack.NewTextBlockObject("mrkdwn", mentionText+message, false, false),
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
		log.Printf("[에러] 요청 파싱 실패: %v", err)
		return respondWithSlackError("요청을 처리할 수 없습니다.")
	}

	triggerID := values.Get("trigger_id")
	if triggerID == "" {
		log.Println("[에러] trigger_id 없음")
		return respondWithSlackError("요청 정보가 부족합니다.")
	}

	// 모달 열기
	modal := buildNewPostModal()
	_, err = app.slack.OpenView(triggerID, modal)
	if err != nil {
		log.Printf("[에러] 모달 열기 실패: %v", err)
		return respondWithSlackError("모달을 열 수 없습니다. 잠시 후 다시 시도해주세요.")
	}

	log.Println("[성공] /bamboo 모달 열기 완료")
	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// Interactive Component 처리
func (app *App) handleInteraction(ctx context.Context, body string) (events.LambdaFunctionURLResponse, error) {
	values, err := url.ParseQuery(body)
	if err != nil {
		log.Printf("[에러] interaction 요청 파싱 실패: %v", err)
		return respondWithSlackError("요청을 처리할 수 없습니다.")
	}

	payloadStr := values.Get("payload")
	if payloadStr == "" {
		log.Println("[에러] payload 없음")
		return respondWithSlackError("요청 정보가 부족합니다.")
	}

	var payload slack.InteractionCallback
	if err := json.Unmarshal([]byte(payloadStr), &payload); err != nil {
		log.Printf("[에러] payload 파싱 실패: %v", err)
		return respondWithSlackError("요청을 처리할 수 없습니다.")
	}

	switch payload.Type {
	case slack.InteractionTypeViewSubmission:
		return app.handleViewSubmission(payload)
	case slack.InteractionTypeBlockActions:
		return app.handleBlockAction(ctx, payload)
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

	// 멘션할 사용자 추출
	var mentions []string
	if mentionBlock, ok := values[BlockIDMention]; ok {
		if mentionInput, ok := mentionBlock[ActionIDMention]; ok {
			mentions = mentionInput.SelectedUsers
		}
	}

	// 카테고리 추출 (새 글에서만)
	category := ""
	if catBlock, ok := values[BlockIDCategory]; ok {
		if catInput, ok := catBlock[ActionIDCategory]; ok {
			if catInput.SelectedOption.Value != "" {
				category = catInput.SelectedOption.Value
			}
		}
	}

	// 긴급도 추출 (새 글에서만, 기본값: normal)
	urgency := "normal"
	if urgBlock, ok := values[BlockIDUrgency]; ok {
		if urgInput, ok := urgBlock[ActionIDUrgency]; ok {
			if urgInput.SelectedOption.Value != "" {
				urgency = urgInput.SelectedOption.Value
			}
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
		if category == "" {
			return respondWithError("카테고리를 선택해주세요")
		}
		return app.postNewMessage(message, nickname, mentions, category, urgency)
	case CallbackNewThread:
		return app.postThreadReply(payload.View.PrivateMetadata, message, nickname, mentions)
	default:
		return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
	}
}

// ─────────────────────────────────────
// 새 메시지 게시
func (app *App) postNewMessage(message, nickname string, mentions []string, category, urgency string) (events.LambdaFunctionURLResponse, error) {
	blocks := buildNewPostBlocks(message, nickname, mentions, category, urgency)

	_, _, err := app.slack.PostMessage(
		TargetChannelID,
		slack.MsgOptionBlocks(blocks...),
	)
	if err != nil {
		log.Printf("[에러] 메시지 게시 실패: %v", err)
		return respondWithError("메시지 게시에 실패했습니다. 잠시 후 다시 시도해주세요.")
	}

	log.Printf("[성공] 익명 메시지 게시 완료 (nickname=%s, category=%s, urgency=%s)", nickname, category, urgency)
	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// 스레드 답글 게시
func (app *App) postThreadReply(metadata, message, nickname string, mentions []string) (events.LambdaFunctionURLResponse, error) {
	parts := strings.Split(metadata, "|")
	if len(parts) != 2 {
		return respondWithError("잘못된 요청입니다")
	}
	channelID, threadTS := parts[0], parts[1]

	blocks := buildThreadReplyBlocks(message, nickname, mentions)

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
func (app *App) handleBlockAction(ctx context.Context, payload slack.InteractionCallback) (events.LambdaFunctionURLResponse, error) {
	for _, action := range payload.ActionCallback.BlockActions {
		switch action.ActionID {
		case ActionReplyButton:
			// 스레드 답글 모달 열기
			channelID := payload.Channel.ID
			threadTS := payload.Message.ThreadTimestamp
			if threadTS == "" {
				threadTS = payload.Message.Timestamp
			}

			modal := buildThreadModal(channelID, threadTS)
			_, err := app.slack.OpenView(payload.TriggerID, modal)
			if err != nil {
				log.Printf("[에러] 스레드 모달 열기 실패: %v", err)
				return respondWithSlackError("답글 모달을 열 수 없습니다. 잠시 후 다시 시도해주세요.")
			}
			log.Printf("[성공] 스레드 답글 모달 열기 완료 (channel=%s, thread=%s)", channelID, threadTS)

		case ActionCompleteButton:
			// 처리 완료 표시
			channelID := payload.Channel.ID
			messageTS := payload.Message.Timestamp
			userID := payload.User.ID

			// 기존 블록 수정: 헤더에 처리완료 추가, 버튼 변경
			var newBlocks []slack.Block
			for _, block := range payload.Message.Blocks.BlockSet {
				switch b := block.(type) {
				case *slack.ContextBlock:
					// emoji_counts 블록은 그대로 유지
					if b.BlockID == "emoji_counts" {
						newBlocks = append(newBlocks, block)
						continue
					}
					// 헤더에 처리완료 표시 추가
					if len(b.ContextElements.Elements) > 0 {
						if textObj, ok := b.ContextElements.Elements[0].(*slack.TextBlockObject); ok {
							newText := textObj.Text + fmt.Sprintf(" │ ✅ 처리됨 (<@%s>)", userID)
							newBlocks = append(newBlocks, slack.NewContextBlock(
								"",
								slack.NewTextBlockObject("mrkdwn", newText, false, false),
							))
							continue
						}
					}
					newBlocks = append(newBlocks, block)
				case *slack.ActionBlock:
					// emoji_actions 블록은 그대로 유지
					if b.BlockID == "emoji_actions" {
						newBlocks = append(newBlocks, block)
						continue
					}
					// 처리완료 버튼 제거, 답글 버튼만 유지
					newBlocks = append(newBlocks, slack.NewActionBlock(
						"",
						slack.NewButtonBlockElement(
							ActionReplyButton,
							"reply",
							slack.NewTextBlockObject("plain_text", "💬 익명 답글 달기", false, false),
						),
					))
				default:
					newBlocks = append(newBlocks, block)
				}
			}

			_, _, _, err := app.slack.UpdateMessage(
				channelID,
				messageTS,
				slack.MsgOptionBlocks(newBlocks...),
			)
			if err != nil {
				log.Printf("[에러] 처리완료 업데이트 실패: %v", err)
				return respondWithSlackError("처리완료 표시에 실패했습니다. 잠시 후 다시 시도해주세요.")
			}
			log.Printf("[성공] 처리완료 표시 (channel=%s, ts=%s, by=%s)", channelID, messageTS, userID)

		case ActionEmojiThumbsUp, ActionEmojiThumbsDown, ActionEmojiHug, ActionEmojiFlex:
			// 이모지 리액션 처리
			return app.handleEmojiReaction(ctx, payload, action.ActionID, action.Value)
		}
	}

	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// 이모지 리액션 처리
func (app *App) handleEmojiReaction(ctx context.Context, payload slack.InteractionCallback, actionID, emoji string) (events.LambdaFunctionURLResponse, error) {
	// Sheets 서비스가 없으면 무시 (기능 비활성화)
	if app.sheets == nil {
		log.Println("[정보] Sheets 서비스 없음, 이모지 리액션 무시")
		return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
	}

	channelID := payload.Channel.ID
	messageTS := payload.Message.Timestamp
	userID := payload.User.ID

	// 중복 체크용 해시 생성
	hash := generateReactionHash(userID, messageTS, emoji)

	// 중복 체크
	isDuplicate, err := app.checkDuplicateReaction(ctx, hash)
	if err != nil {
		log.Printf("[경고] 중복 체크 실패: %v", err)
		// 에러가 나도 진행 (사용자 경험 우선)
	}

	if isDuplicate {
		log.Printf("[정보] 중복 리액션 무시 (user=%s, emoji=%s)", userID[:8], emoji)
		return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
	}

	// 리액션 기록
	if err := app.recordReaction(ctx, hash, messageTS, emoji); err != nil {
		log.Printf("[에러] 리액션 기록 실패: %v", err)
		return respondWithSlackError("리액션 저장에 실패했습니다.")
	}

	// 새 카운트 조회
	counts, err := app.getEmojiCounts(ctx, messageTS)
	if err != nil {
		log.Printf("[경고] 카운트 조회 실패: %v", err)
	}

	// 메시지 블록 업데이트
	var newBlocks []slack.Block
	for _, block := range payload.Message.Blocks.BlockSet {
		switch b := block.(type) {
		case *slack.ContextBlock:
			if b.BlockID == "emoji_counts" {
				// 이모지 카운트 업데이트
				newBlocks = append(newBlocks, slack.NewContextBlock(
					"emoji_counts",
					slack.NewTextBlockObject("mrkdwn", formatEmojiCounts(counts), false, false),
				))
				continue
			}
			newBlocks = append(newBlocks, block)
		default:
			newBlocks = append(newBlocks, block)
		}
	}

	_, _, _, err = app.slack.UpdateMessage(
		channelID,
		messageTS,
		slack.MsgOptionBlocks(newBlocks...),
	)
	if err != nil {
		log.Printf("[에러] 메시지 업데이트 실패: %v", err)
		return respondWithSlackError("리액션 업데이트에 실패했습니다.")
	}

	log.Printf("[성공] 이모지 리액션 추가 (emoji=%s, ts=%s)", emoji, messageTS)
	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// 이모지 관련 헬퍼 함수

// 익명 해시 생성: hash(userID + messageTS + emoji)
func generateReactionHash(userID, messageTS, emoji string) string {
	data := userID + "|" + messageTS + "|" + emoji
	hash := sha256.Sum256([]byte(data))
	return hex.EncodeToString(hash[:16]) // 32자 해시
}

// Google Sheets에서 중복 체크 (이미 리액션했는지)
func (app *App) checkDuplicateReaction(ctx context.Context, hash string) (bool, error) {
	if app.sheets == nil {
		return false, fmt.Errorf("Sheets 서비스 없음")
	}

	// A열에서 해시 검색
	resp, err := app.sheets.Spreadsheets.Values.Get(app.cfg.SheetsID, "reactions!A:A").Context(ctx).Do()
	if err != nil {
		return false, fmt.Errorf("Sheets 조회 실패: %w", err)
	}

	for _, row := range resp.Values {
		if len(row) > 0 && row[0].(string) == hash {
			return true, nil // 중복
		}
	}
	return false, nil
}

// Google Sheets에 리액션 기록
func (app *App) recordReaction(ctx context.Context, hash, messageTS, emoji string) error {
	if app.sheets == nil {
		return fmt.Errorf("Sheets 서비스 없음")
	}

	values := [][]interface{}{
		{hash, messageTS, emoji, time.Now().Format(time.RFC3339)},
	}

	_, err := app.sheets.Spreadsheets.Values.Append(
		app.cfg.SheetsID,
		"reactions!A:D",
		&sheets.ValueRange{Values: values},
	).ValueInputOption("RAW").Context(ctx).Do()

	return err
}

// 특정 메시지의 이모지 카운트 조회
func (app *App) getEmojiCounts(ctx context.Context, messageTS string) (map[string]int, error) {
	counts := map[string]int{
		"thumbsup":   0,
		"thumbsdown": 0,
		"hug":        0,
		"flex":       0,
	}

	if app.sheets == nil {
		return counts, nil
	}

	resp, err := app.sheets.Spreadsheets.Values.Get(app.cfg.SheetsID, "reactions!A:C").Context(ctx).Do()
	if err != nil {
		return counts, fmt.Errorf("Sheets 조회 실패: %w", err)
	}

	for _, row := range resp.Values {
		if len(row) >= 3 {
			ts, ok1 := row[1].(string)
			emoji, ok2 := row[2].(string)
			if ok1 && ok2 && ts == messageTS {
				counts[emoji]++
			}
		}
	}

	return counts, nil
}

// 이모지 카운트 텍스트 생성
func formatEmojiCounts(counts map[string]int) string {
	return fmt.Sprintf("👍 %d │ 👎 %d │ 🤗 %d │ 💪 %d",
		counts["thumbsup"], counts["thumbsdown"], counts["hug"], counts["flex"])
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

// Slack에 에러 메시지 반환 (slash command/interactive용)
// Slack은 200 OK + 텍스트 메시지를 받아야 사용자에게 표시함
func respondWithSlackError(message string) (events.LambdaFunctionURLResponse, error) {
	return events.LambdaFunctionURLResponse{
		StatusCode: 200,
		Headers:    map[string]string{"Content-Type": "text/plain; charset=utf-8"},
		Body:       "⚠️ " + message,
	}, nil
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
	// Body 처리 (Base64 인코딩된 경우 디코딩)
	var body []byte
	var bodyStr string
	if event.IsBase64Encoded {
		decoded, err := base64.StdEncoding.DecodeString(event.Body)
		if err != nil {
			log.Printf("[에러] Base64 디코딩 실패: %v", err)
			return respondWithSlackError("요청을 처리할 수 없습니다.")
		}
		body = decoded
		bodyStr = string(decoded)
	} else {
		body = []byte(event.Body)
		bodyStr = event.Body
	}

	// 서명 검증
	if err := verifySlackSignature(event.Headers, body, app.cfg.SlackSigningSecret); err != nil {
		log.Printf("[에러] 서명 검증 실패: %v", err)
		return respondWithSlackError("인증에 실패했습니다.")
	}

	// Slash Command인지 Interactive Component인지 구분
	if strings.Contains(bodyStr, "command=%2Fbamboo") || strings.Contains(bodyStr, "command=/bamboo") {
		log.Println("[요청] Slash Command 처리")
		return app.handleSlashCommand(bodyStr)
	}

	if strings.Contains(bodyStr, "payload=") {
		log.Println("[요청] Interactive Component 처리")
		return app.handleInteraction(ctx, bodyStr)
	}

	log.Printf("[무시] 알 수 없는 요청 타입: %s", bodyStr[:min(100, len(bodyStr))])
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
	app, err = NewApp(ctx, cfg)
	if err != nil {
		log.Fatalf("[치명적] 앱 초기화 실패: %v", err)
	}
}

func main() {
	lambda.Start(app.handler)
}

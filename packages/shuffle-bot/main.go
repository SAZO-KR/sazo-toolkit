package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"math/rand/v2"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/slack-go/slack"
)

// ─────────────────────────────────────
// 상수
const (
	// Callback IDs
	CallbackShuffle = "shuffle_submit"

	// Block IDs
	BlockIDSourceType = "source_type_block"
	BlockIDUsergroup  = "usergroup_block"
	BlockIDUsers      = "users_block"
	BlockIDExclude    = "exclude_block"
	BlockIDMode       = "mode_block"
	BlockIDCount      = "count_block"
	BlockIDTitle      = "title_block"

	// Action IDs
	ActionSourceType = "source_type_action"
	ActionUsergroup  = "usergroup_action"
	ActionUsers      = "users_action"
	ActionExclude    = "exclude_action"
	ActionMode       = "mode_action"
	ActionCount      = "count_action"
	ActionTitle      = "title_action"

	// Source types
	SourceChannel   = "channel"
	SourceUsergroup = "usergroup"
	SourceManual    = "manual"

	// Modes
	ModeShuffle  = "shuffle"
	ModeRoulette = "roulette"
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
type channelMembersEntry struct {
	members   []string
	fetchedAt time.Time
}

type App struct {
	cfg              *Config
	slack            *slack.Client
	botUserID        string
	userCache        map[string]string
	userLocale       map[string]string
	userCacheMu      sync.RWMutex
	userCacheAt      time.Time
	channelMembers   map[string]channelMembersEntry
	channelMembersMu sync.RWMutex
}

func NewApp(cfg *Config) (*App, error) {
	if cfg.SlackBotToken == "" || cfg.SlackSigningSecret == "" {
		return nil, fmt.Errorf("Slack 설정 누락")
	}

	client := slack.New(cfg.SlackBotToken)
	resp, err := client.AuthTest()
	if err != nil {
		return nil, fmt.Errorf("봇 인증 실패: %w", err)
	}

	log.Printf("[디버그] 봇 유저 ID: %s", resp.UserID)
	return &App{cfg: cfg, slack: client, botUserID: resp.UserID}, nil
}

// ─────────────────────────────────────
// 모달 상태 (private_metadata에 저장)
type ModalState struct {
	SourceType        string `json:"s"`
	Mode              string `json:"m"`
	ResponseChannel   string `json:"rc"`
	SelectedUsergroup string `json:"su,omitempty"`
	Title             string `json:"t,omitempty"`
}

func encodeState(state ModalState) string {
	b, _ := json.Marshal(state)
	return string(b)
}

func decodeState(s string) ModalState {
	var state ModalState
	json.Unmarshal([]byte(s), &state)
	if state.SourceType == "" {
		state.SourceType = SourceChannel
	}
	if state.Mode == "" {
		state.Mode = ModeShuffle
	}
	return state
}

// ─────────────────────────────────────
// 모달 생성
func (app *App) buildShuffleModal(state ModalState, usergroupOpts []*slack.OptionBlockObject, excludeOpts []*slack.OptionBlockObject, channelErr bool) slack.ModalViewRequest {
	var blocks []slack.Block

	// ── 대상 선택 방식 (라디오) ──
	sourceOptions := []*slack.OptionBlockObject{
		slack.NewOptionBlockObject(SourceChannel, slack.NewTextBlockObject("plain_text", "📢 이 채널 멤버", false, false), nil),
		slack.NewOptionBlockObject(SourceUsergroup, slack.NewTextBlockObject("plain_text", "👥 유저그룹", false, false), nil),
		slack.NewOptionBlockObject(SourceManual, slack.NewTextBlockObject("plain_text", "✋ 직접 선택", false, false), nil),
	}

	var initialSource *slack.OptionBlockObject
	for _, opt := range sourceOptions {
		if opt.Value == state.SourceType {
			initialSource = opt
			break
		}
	}

	sourceRadio := slack.NewRadioButtonsBlockElement(ActionSourceType, sourceOptions...)
	if initialSource != nil {
		sourceRadio.InitialOption = initialSource
	}

	sourceBlock := slack.NewInputBlock(
		BlockIDSourceType,
		slack.NewTextBlockObject("plain_text", "대상 선택 방식", false, false),
		slack.NewTextBlockObject("plain_text", "셔플/룰렛 대상을 어떻게 선택할지 골라주세요", false, false),
		sourceRadio,
	)
	sourceBlock.DispatchAction = true
	blocks = append(blocks, sourceBlock)

	// ── 소스 타입별 조건부 필드 ──
	switch state.SourceType {
	case SourceChannel:
		if channelErr {
			blocks = append(blocks, slack.NewContextBlock("",
				slack.NewTextBlockObject("mrkdwn", "⚠️ 이 채널의 멤버를 가져올 수 없습니다. `/invite @Sazo Toolkit` 으로 봇을 초대해주세요.\n다른 대상을 선택할 수도 있습니다.", false, false),
			))
		} else {
			if len(excludeOpts) > 0 {
				excludeSelect := slack.NewOptionsMultiSelectBlockElement(
					"multi_static_select",
					slack.NewTextBlockObject("plain_text", "제외할 사람 선택...", false, false),
					ActionExclude,
					excludeOpts...,
				)
				excludeBlock := slack.NewInputBlock(
					BlockIDExclude,
					slack.NewTextBlockObject("plain_text", "제외할 사람 (선택사항)", false, false),
					slack.NewTextBlockObject("plain_text", "셔플/룰렛에서 제외할 사람을 선택하세요 (봇은 자동 제외)", false, false),
					excludeSelect,
				)
				excludeBlock.Optional = true
				blocks = append(blocks, excludeBlock)
			}
		}

	case SourceUsergroup:
		if len(usergroupOpts) > 0 {
			ugSelect := slack.NewOptionsSelectBlockElement(
				"static_select",
				slack.NewTextBlockObject("plain_text", "유저그룹 선택...", false, false),
				ActionUsergroup,
				usergroupOpts...,
			)
			if state.SelectedUsergroup != "" {
				for _, opt := range usergroupOpts {
					if opt.Value == state.SelectedUsergroup {
						ugSelect.InitialOption = opt
						break
					}
				}
			}
			ugBlock := slack.NewInputBlock(
				BlockIDUsergroup,
				slack.NewTextBlockObject("plain_text", "유저그룹", false, false),
				slack.NewTextBlockObject("plain_text", "멤버를 가져올 유저그룹을 선택하세요", false, false),
				ugSelect,
			)
			ugBlock.DispatchAction = true
			blocks = append(blocks, ugBlock)
		} else {
			blocks = append(blocks, slack.NewSectionBlock(
				slack.NewTextBlockObject("mrkdwn", "⚠️ 워크스페이스에 유저그룹이 없습니다.", false, false),
				nil, nil,
			))
		}

		if len(excludeOpts) > 0 {
			excludeSelect := slack.NewOptionsMultiSelectBlockElement(
				"multi_static_select",
				slack.NewTextBlockObject("plain_text", "제외할 사람 선택...", false, false),
				ActionExclude,
				excludeOpts...,
			)
			excludeBlock := slack.NewInputBlock(
				BlockIDExclude,
				slack.NewTextBlockObject("plain_text", "제외할 사람 (선택사항)", false, false),
				slack.NewTextBlockObject("plain_text", "셔플/룰렛에서 제외할 사람을 선택하세요 (봇은 자동 제외)", false, false),
				excludeSelect,
			)
			excludeBlock.Optional = true
			blocks = append(blocks, excludeBlock)
		}

	case SourceManual:
		usersSelect := slack.NewOptionsMultiSelectBlockElement(
			"multi_users_select",
			slack.NewTextBlockObject("plain_text", "사람 선택...", false, false),
			ActionUsers,
		)
		blocks = append(blocks, slack.NewInputBlock(
			BlockIDUsers,
			slack.NewTextBlockObject("plain_text", "참여자", false, false),
			slack.NewTextBlockObject("plain_text", "셔플/룰렛에 참여할 사람들을 선택하세요", false, false),
			usersSelect,
		))
	}

	// ── 구분선 ──
	blocks = append(blocks, slack.NewDividerBlock())

	// ── 모드 선택 (라디오) ──
	modeOptions := []*slack.OptionBlockObject{
		slack.NewOptionBlockObject(
			ModeShuffle,
			slack.NewTextBlockObject("plain_text", "🎲 셔플", false, false),
			slack.NewTextBlockObject("plain_text", "전체 순서를 랜덤으로 섞어서 보여줍니다", false, false),
		),
		slack.NewOptionBlockObject(
			ModeRoulette,
			slack.NewTextBlockObject("plain_text", "🎰 룰렛", false, false),
			slack.NewTextBlockObject("plain_text", "지정한 인원 수만큼 당첨자를 뽑습니다", false, false),
		),
	}

	var initialMode *slack.OptionBlockObject
	for _, opt := range modeOptions {
		if opt.Value == state.Mode {
			initialMode = opt
			break
		}
	}

	modeRadio := slack.NewRadioButtonsBlockElement(ActionMode, modeOptions...)
	if initialMode != nil {
		modeRadio.InitialOption = initialMode
	}

	modeBlock := slack.NewInputBlock(
		BlockIDMode,
		slack.NewTextBlockObject("plain_text", "모드", false, false),
		nil,
		modeRadio,
	)
	modeBlock.DispatchAction = true
	blocks = append(blocks, modeBlock)

	// ── 뽑을 인원 수 (룰렛 모드에서만) ──
	if state.Mode == ModeRoulette {
		countInput := slack.NewPlainTextInputBlockElement(
			slack.NewTextBlockObject("plain_text", "숫자를 입력하세요 (예: 1)", false, false),
			ActionCount,
		)
		blocks = append(blocks, slack.NewInputBlock(
			BlockIDCount,
			slack.NewTextBlockObject("plain_text", "뽑을 인원 수", false, false),
			slack.NewTextBlockObject("plain_text", "룰렛으로 뽑을 당첨자 수를 입력하세요", false, false),
			countInput,
		))
	}

	// ── 구분선 + 제목 ──
	blocks = append(blocks, slack.NewDividerBlock())

	titleInput := slack.NewPlainTextInputBlockElement(
		slack.NewTextBlockObject("plain_text", "예: 점심 당번 정하기", false, false),
		ActionTitle,
	)
	titleBlock := slack.NewInputBlock(
		BlockIDTitle,
		slack.NewTextBlockObject("plain_text", "제목 (선택사항)", false, false),
		slack.NewTextBlockObject("plain_text", "결과 메시지에 표시할 제목을 입력하세요", false, false),
		titleInput,
	)
	titleBlock.Optional = true
	blocks = append(blocks, titleBlock)

	return slack.ModalViewRequest{
		Type:            slack.ViewType("modal"),
		CallbackID:      CallbackShuffle,
		PrivateMetadata: encodeState(state),
		Title:           slack.NewTextBlockObject("plain_text", "🎲 셔플 / 룰렛", false, false),
		Submit:          slack.NewTextBlockObject("plain_text", "실행!", false, false),
		Close:           slack.NewTextBlockObject("plain_text", "취소", false, false),
		Blocks: slack.Blocks{
			BlockSet: blocks,
		},
	}
}

// ─────────────────────────────────────
// 유저그룹 옵션 조회
func (app *App) fetchUsergroupOptions() []*slack.OptionBlockObject {
	groups, err := app.slack.GetUserGroups(slack.GetUserGroupsOptionIncludeUsers(false))
	if err != nil {
		log.Printf("[경고] 유저그룹 조회 실패: %v", err)
		return nil
	}

	var opts []*slack.OptionBlockObject
	for _, g := range groups {
		if g.DeletedBy != "" {
			continue
		}
		label := g.Name
		if g.Handle != "" {
			label = fmt.Sprintf("%s (@%s)", g.Name, g.Handle)
		}
		opts = append(opts, slack.NewOptionBlockObject(
			g.ID,
			slack.NewTextBlockObject("plain_text", truncate(label, 75), false, false),
			nil,
		))
	}
	return opts
}

// ─────────────────────────────────────
// 채널 멤버 조회 (페이지네이션 처리)
func (app *App) getChannelMembers(channelID string) ([]string, error) {
	app.channelMembersMu.RLock()
	if entry, ok := app.channelMembers[channelID]; ok && time.Since(entry.fetchedAt) < 2*time.Minute {
		app.channelMembersMu.RUnlock()
		return entry.members, nil
	}
	app.channelMembersMu.RUnlock()

	var allMembers []string
	cursor := ""

	for {
		params := &slack.GetUsersInConversationParameters{
			ChannelID: channelID,
			Cursor:    cursor,
			Limit:     200,
		}
		members, nextCursor, err := app.slack.GetUsersInConversation(params)
		if err != nil {
			return nil, fmt.Errorf("채널 멤버 조회 실패: %w", err)
		}
		allMembers = append(allMembers, members...)
		if nextCursor == "" {
			break
		}
		cursor = nextCursor
	}

	app.channelMembersMu.Lock()
	if app.channelMembers == nil {
		app.channelMembers = make(map[string]channelMembersEntry)
	}
	app.channelMembers[channelID] = channelMembersEntry{members: allMembers, fetchedAt: time.Now()}
	app.channelMembersMu.Unlock()

	return allMembers, nil
}

// ─────────────────────────────────────
// 유저그룹 멤버 조회
func (app *App) getUsergroupMembers(usergroupID string) ([]string, error) {
	members, err := app.slack.GetUserGroupMembers(usergroupID)
	if err != nil {
		return nil, fmt.Errorf("유저그룹 멤버 조회 실패: %w", err)
	}
	return members, nil
}

// ─────────────────────────────────────
// 유저 캐시 (users.list 1회 호출로 전체 유저 이름 캐싱)
func (app *App) refreshUserCache() {
	users, err := app.slack.GetUsers(slack.GetUsersOptionLimit(0))
	if err != nil {
		log.Printf("[경고] 유저 목록 조회 실패: %v", err)
		return
	}

	cache := make(map[string]string, len(users))
	locale := make(map[string]string, len(users))
	for _, u := range users {
		if u.IsBot || u.Deleted {
			continue
		}
		name := u.Profile.DisplayName
		if name == "" {
			name = u.RealName
		}
		if name == "" {
			name = u.Name
		}
		cache[u.ID] = name
		if u.Locale != "" {
			locale[u.ID] = u.Locale
		}
	}

	app.userCacheMu.Lock()
	app.userCache = cache
	app.userLocale = locale
	app.userCacheAt = time.Now()
	app.userCacheMu.Unlock()
	log.Printf("[디버그] 유저 캐시 갱신 완료 (%d명)", len(cache))
}

func (app *App) getUserLocale(userID string) string {
	app.userCacheMu.RLock()
	if app.userLocale != nil && time.Since(app.userCacheAt) < 10*time.Minute {
		defer app.userCacheMu.RUnlock()
		if l, ok := app.userLocale[userID]; ok {
			return l
		}
		return "en-US"
	}
	app.userCacheMu.RUnlock()

	app.refreshUserCache()

	app.userCacheMu.RLock()
	defer app.userCacheMu.RUnlock()
	if l, ok := app.userLocale[userID]; ok {
		return l
	}
	return "en-US"
}

func (app *App) getUserNames() map[string]string {
	app.userCacheMu.RLock()
	if app.userCache != nil && time.Since(app.userCacheAt) < 10*time.Minute {
		defer app.userCacheMu.RUnlock()
		return app.userCache
	}
	app.userCacheMu.RUnlock()

	app.refreshUserCache()

	app.userCacheMu.RLock()
	defer app.userCacheMu.RUnlock()
	return app.userCache
}

func (app *App) fetchMemberOptions(userIDs []string) []*slack.OptionBlockObject {
	names := app.getUserNames()
	var opts []*slack.OptionBlockObject
	for _, uid := range userIDs {
		if uid == app.botUserID {
			continue
		}
		name, ok := names[uid]
		if !ok {
			continue
		}
		opts = append(opts, slack.NewOptionBlockObject(
			uid,
			slack.NewTextBlockObject("plain_text", truncate(name, 75), false, false),
			nil,
		))
	}
	return opts
}

// ─────────────────────────────────────
// 필터링 + 셔플
func filterAndShuffle(members []string, exclude map[string]bool, validUsers map[string]string) []string {
	seen := make(map[string]bool)
	var filtered []string
	for _, m := range members {
		if exclude[m] || seen[m] {
			continue
		}
		if validUsers != nil {
			if _, ok := validUsers[m]; !ok {
				continue
			}
		}
		seen[m] = true
		filtered = append(filtered, m)
	}

	// Fisher-Yates shuffle
	rand.Shuffle(len(filtered), func(i, j int) {
		filtered[i], filtered[j] = filtered[j], filtered[i]
	})

	return filtered
}

// ─────────────────────────────────────
// 결과 메시지 블록 생성

func buildShuffleResultBlocks(shuffled []string, invokerID, title string) []slack.Block {
	total := len(shuffled)

	headerText := "🎲 셔플 결과"
	if title != "" {
		headerText = "🎲 " + title
	}

	var sb strings.Builder
	for i, userID := range shuffled {
		sb.WriteString(fmt.Sprintf("%d. <@%s>\n", i+1, userID))
	}

	return []slack.Block{
		slack.NewHeaderBlock(
			slack.NewTextBlockObject("plain_text", truncate(headerText, 150), false, false),
		),
		slack.NewContextBlock("",
			slack.NewTextBlockObject("mrkdwn",
				fmt.Sprintf("실행: <@%s> │ %d명 참여", invokerID, total), false, false),
		),
		slack.NewDividerBlock(),
		slack.NewSectionBlock(
			slack.NewTextBlockObject("mrkdwn", sb.String(), false, false),
			nil, nil,
		),
	}
}

func buildRouletteResultBlocks(winners []string, total, requestedCount int, invokerID, title string) []slack.Block {
	headerText := "🎰 룰렛 결과"
	if title != "" {
		headerText = "🎰 " + title
	}

	var sb strings.Builder
	for i, userID := range winners {
		switch i {
		case 0:
			sb.WriteString(fmt.Sprintf("🥇 <@%s>\n", userID))
		case 1:
			sb.WriteString(fmt.Sprintf("🥈 <@%s>\n", userID))
		case 2:
			sb.WriteString(fmt.Sprintf("🥉 <@%s>\n", userID))
		default:
			sb.WriteString(fmt.Sprintf("🎉 <@%s>\n", userID))
		}
	}

	blocks := []slack.Block{
		slack.NewHeaderBlock(
			slack.NewTextBlockObject("plain_text", truncate(headerText, 150), false, false),
		),
		slack.NewContextBlock("",
			slack.NewTextBlockObject("mrkdwn",
				fmt.Sprintf("실행: <@%s> │ %d명 중 %d명 당첨!", invokerID, total, len(winners)), false, false),
		),
		slack.NewDividerBlock(),
		slack.NewSectionBlock(
			slack.NewTextBlockObject("mrkdwn", sb.String(), false, false),
			nil, nil,
		),
	}

	if requestedCount > total {
		blocks = append(blocks, slack.NewContextBlock("",
			slack.NewTextBlockObject("mrkdwn",
				fmt.Sprintf("⚠️ %d명을 뽑으려 했으나 대상이 %d명이라 %d명만 추첨했습니다", requestedCount, total, len(winners)), false, false),
		))
	}

	return blocks
}

// ─────────────────────────────────────
// Quick Command 파싱
var (
	userMentionRegex      = regexp.MustCompile(`<@([A-Za-z0-9]+)(?:\|[^>]*)?>`)
	usergroupMentionRegex = regexp.MustCompile(`<!subteam\^([A-Za-z0-9]+)(?:\|[^>]*)?>`)
	hereMentionRegex      = regexp.MustCompile(`<!(?:here|channel|everyone)(?:\|[^>]*)?>|@here|@channel|@everyone`)
)

type ParsedMentions struct {
	UserIDs      []string
	UsergroupIDs []string
	HasHere      bool
	Remaining    string
}

func parseMentions(text string) ParsedMentions {
	var pm ParsedMentions
	for _, m := range userMentionRegex.FindAllStringSubmatch(text, -1) {
		pm.UserIDs = append(pm.UserIDs, m[1])
	}
	for _, m := range usergroupMentionRegex.FindAllStringSubmatch(text, -1) {
		pm.UsergroupIDs = append(pm.UsergroupIDs, m[1])
	}
	pm.HasHere = hereMentionRegex.MatchString(text)

	r := userMentionRegex.ReplaceAllString(text, "")
	r = usergroupMentionRegex.ReplaceAllString(r, "")
	r = hereMentionRegex.ReplaceAllString(r, "")
	pm.Remaining = r
	return pm
}

type QuickCommand struct {
	Users               []string
	UsergroupIDs        []string
	ExcludeUsers        []string
	ExcludeUsergroupIDs []string
	UseCurrentChannel   bool
	Mode                string
	Count               int
	Title               string
}

func parseQuickCommand(text string) QuickCommand {
	cmd := QuickCommand{Mode: ModeShuffle, Count: 1}

	mainPart := text
	sep := "--"
	idx := strings.Index(text, "--")
	if idx < 0 {
		sep = "—"
		idx = strings.Index(text, "—")
	}
	if idx >= 0 {
		mainPart = text[:idx]
		excl := parseMentions(text[idx+len(sep):])
		cmd.ExcludeUsers = excl.UserIDs
		cmd.ExcludeUsergroupIDs = excl.UsergroupIDs
	}

	main := parseMentions(mainPart)
	cmd.Users = main.UserIDs
	cmd.UsergroupIDs = main.UsergroupIDs
	cmd.UseCurrentChannel = main.HasHere

	remaining := main.Remaining
	words := strings.Fields(remaining)
	if len(words) > 0 {
		if count, err := strconv.Atoi(words[0]); err == nil && count > 0 {
			cmd.Mode = ModeRoulette
			cmd.Count = count
			remaining = strings.Join(words[1:], " ")
		} else if len(words) > 1 {
			last := words[len(words)-1]
			if count, err := strconv.Atoi(last); err == nil && count > 0 {
				cmd.Mode = ModeRoulette
				cmd.Count = count
				remaining = strings.Join(words[:len(words)-1], " ")
			}
		}
	}

	if cmd.Count < 1 {
		cmd.Count = 1
	}
	cmd.Title = strings.TrimSpace(remaining)

	return cmd
}

func (app *App) handleQuickCommand(text, responseChannel, invokerID, locale string) (events.LambdaFunctionURLResponse, error) {
	log.Printf("[디버그] 퀵커맨드 원본 text=%q", text)
	cmd := parseQuickCommand(text)
	log.Printf("[디버그] 파싱 결과: users=%v, usergroups=%v, here=%v, excludeUsers=%v, excludeGroups=%v, mode=%s, count=%d, title=%q",
		cmd.Users, cmd.UsergroupIDs, cmd.UseCurrentChannel, cmd.ExcludeUsers, cmd.ExcludeUsergroupIDs, cmd.Mode, cmd.Count, cmd.Title)

	var members []string
	if cmd.UseCurrentChannel {
		var err error
		members, err = app.getChannelMembers(responseChannel)
		if err != nil {
			log.Printf("[에러] 빠른 실행 채널 멤버 조회 실패: %v", err)
			return respondWithSlackError("이 채널의 멤버를 가져올 수 없습니다. `/invite @Sazo Toolkit` 으로 봇을 초대해주세요.")
		}
	} else if len(cmd.UsergroupIDs) > 0 {
		for _, ugID := range cmd.UsergroupIDs {
			ugMembers, err := app.getUsergroupMembers(ugID)
			if err != nil {
				log.Printf("[에러] 빠른 실행 유저그룹 멤버 조회 실패: %v", err)
				return respondWithSlackError("유저그룹 멤버를 가져올 수 없습니다.")
			}
			members = append(members, ugMembers...)
		}
	} else if len(cmd.Users) > 0 {
		members = cmd.Users
	} else {
		return respondWithHelpMessage(locale)
	}

	excludeSet := map[string]bool{app.botUserID: true}
	for _, uid := range cmd.ExcludeUsers {
		excludeSet[uid] = true
	}
	for _, ugID := range cmd.ExcludeUsergroupIDs {
		ugMembers, err := app.getUsergroupMembers(ugID)
		if err == nil {
			for _, uid := range ugMembers {
				excludeSet[uid] = true
			}
		}
	}
	shuffled := filterAndShuffle(members, excludeSet, app.getUserNames())

	if len(shuffled) == 0 {
		return respondWithSlackError("셔플할 대상이 없습니다.")
	}

	var resultBlocks []slack.Block
	switch cmd.Mode {
	case ModeRoulette:
		requestedCount := cmd.Count
		if cmd.Count > len(shuffled) {
			cmd.Count = len(shuffled)
		}
		resultBlocks = buildRouletteResultBlocks(shuffled[:cmd.Count], len(shuffled), requestedCount, invokerID, cmd.Title)
	default:
		resultBlocks = buildShuffleResultBlocks(shuffled, invokerID, cmd.Title)
	}

	_, _, err := app.slack.PostMessage(responseChannel, slack.MsgOptionBlocks(resultBlocks...))
	if err != nil {
		log.Printf("[에러] 빠른 실행 결과 전송 실패: %v", err)
		return respondWithSlackError("결과 메시지 전송에 실패했습니다.")
	}

	log.Printf("[성공] 빠른 실행 완료 (mode=%s, total=%d, invoker=%s)", cmd.Mode, len(shuffled), invokerID)
	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// Slash Command 처리
func (app *App) handleSlashCommand(body string) (events.LambdaFunctionURLResponse, error) {
	values, err := url.ParseQuery(body)
	if err != nil {
		log.Printf("[에러] 요청 파싱 실패: %v", err)
		return respondWithSlackError("요청을 처리할 수 없습니다.")
	}

	channelID := values.Get("channel_id")
	invokerID := values.Get("user_id")
	text := strings.TrimSpace(values.Get("text"))

	locale := app.getUserLocale(invokerID)
	if strings.EqualFold(text, "help") {
		return respondWithHelpMessage(locale)
	}
	if text != "" {
		return app.handleQuickCommand(text, channelID, invokerID, locale)
	}

	triggerID := values.Get("trigger_id")
	if triggerID == "" {
		log.Println("[에러] trigger_id 없음")
		return respondWithSlackError("요청 정보가 부족합니다.")
	}

	state := ModalState{
		SourceType:      SourceChannel,
		Mode:            ModeShuffle,
		ResponseChannel: channelID,
	}

	// 현재 채널 멤버 미리 조회
	var excludeOpts []*slack.OptionBlockObject
	var channelErr bool
	members, mErr := app.getChannelMembers(channelID)
	if mErr != nil {
		log.Printf("[경고] 채널 멤버 조회 실패 (channel=%s): %v", channelID, mErr)
		channelErr = true
	} else {
		allOpts := app.fetchMemberOptions(members)
		if len(allOpts) <= 100 {
			excludeOpts = allOpts
		}
	}

	modal := app.buildShuffleModal(state, nil, excludeOpts, channelErr)
	_, err = app.slack.OpenView(triggerID, modal)
	if err != nil {
		log.Printf("[에러] 모달 열기 실패: %v", err)
		return respondWithSlackError("모달을 열 수 없습니다. 잠시 후 다시 시도해주세요.")
	}

	log.Printf("[성공] /shuffle 모달 열기 완료 (channel=%s)", channelID)
	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// Interactive Component 처리
func (app *App) handleInteraction(body string) (events.LambdaFunctionURLResponse, error) {
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
		return app.handleBlockAction(payload)
	default:
		log.Printf("[무시] 처리하지 않는 interaction type: %s", payload.Type)
		return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
	}
}

// ─────────────────────────────────────
// Block Action 처리 (라디오 버튼 변경 → 모달 업데이트)
func (app *App) handleBlockAction(payload slack.InteractionCallback) (events.LambdaFunctionURLResponse, error) {
	state := decodeState(payload.View.PrivateMetadata)
	needsUpdate := false

	for _, action := range payload.ActionCallback.BlockActions {
		switch action.ActionID {
		case ActionSourceType:
			newSource := action.SelectedOption.Value
			if newSource != state.SourceType {
				state.SourceType = newSource
				state.SelectedUsergroup = ""
				needsUpdate = true
			}
		case ActionMode:
			newMode := action.SelectedOption.Value
			if newMode != state.Mode {
				state.Mode = newMode
				needsUpdate = true
			}
		case ActionUsergroup:
			state.SelectedUsergroup = action.SelectedOption.Value
			needsUpdate = true
		}
	}

	if needsUpdate {
		var ugOpts []*slack.OptionBlockObject
		var excludeOpts []*slack.OptionBlockObject
		var channelErr bool

		switch state.SourceType {
		case SourceChannel:
			members, err := app.getChannelMembers(state.ResponseChannel)
			if err != nil {
				log.Printf("[경고] 채널 멤버 조회 실패: %v", err)
				channelErr = true
			} else {
				allOpts := app.fetchMemberOptions(members)
				if len(allOpts) <= 100 {
					excludeOpts = allOpts
				}
			}
		case SourceUsergroup:
			ugOpts = app.fetchUsergroupOptions()
			if state.SelectedUsergroup != "" {
				members, err := app.getUsergroupMembers(state.SelectedUsergroup)
				if err == nil {
					allOpts := app.fetchMemberOptions(members)
					if len(allOpts) <= 100 {
						excludeOpts = allOpts
					}
				}
			}
		}

		modal := app.buildShuffleModal(state, ugOpts, excludeOpts, channelErr)
		_, err := app.slack.UpdateView(modal, "", "", payload.View.ID)
		if err != nil {
			log.Printf("[에러] 모달 업데이트 실패: %v", err)
		}
	}

	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// View Submission 처리 (셔플/룰렛 실행)
func (app *App) handleViewSubmission(payload slack.InteractionCallback) (events.LambdaFunctionURLResponse, error) {
	state := decodeState(payload.View.PrivateMetadata)
	values := payload.View.State.Values
	invokerID := payload.User.ID

	// ── 대상 멤버 수집 ──
	var members []string
	var err error

	switch state.SourceType {
	case SourceChannel:
		members, err = app.getChannelMembers(state.ResponseChannel)
		if err != nil {
			log.Printf("[에러] %v", err)
			return respondWithModalError(BlockIDSourceType, "이 채널의 멤버를 가져올 수 없습니다. `/invite @Sazo Toolkit` 으로 봇을 초대해주세요.")
		}

	case SourceUsergroup:
		ugID := ""
		if block, ok := values[BlockIDUsergroup]; ok {
			if action, ok := block[ActionUsergroup]; ok {
				ugID = action.SelectedOption.Value
			}
		}
		if ugID == "" {
			return respondWithModalError(BlockIDUsergroup, "유저그룹을 선택해주세요")
		}
		members, err = app.getUsergroupMembers(ugID)
		if err != nil {
			log.Printf("[에러] %v", err)
			return respondWithModalError(BlockIDUsergroup, "유저그룹 멤버를 가져올 수 없습니다.")
		}

	case SourceManual:
		if block, ok := values[BlockIDUsers]; ok {
			if action, ok := block[ActionUsers]; ok {
				members = action.SelectedUsers
			}
		}
		if len(members) == 0 {
			return respondWithModalError(BlockIDUsers, "참여자를 선택해주세요")
		}
	}

	// ── 제외 인원 처리 ──
	excludeSet := map[string]bool{
		app.botUserID: true, // 봇은 항상 제외
	}
	if block, ok := values[BlockIDExclude]; ok {
		if action, ok := block[ActionExclude]; ok {
			for _, uid := range action.SelectedUsers {
				excludeSet[uid] = true
			}
			for _, opt := range action.SelectedOptions {
				excludeSet[opt.Value] = true
			}
		}
	}

	// ── 필터링 + 셔플 ──
	shuffled := filterAndShuffle(members, excludeSet, app.getUserNames())

	if len(shuffled) == 0 {
		return respondWithModalError(BlockIDSourceType, "셔플할 대상이 없습니다. 제외 인원을 확인해주세요.")
	}

	// ── 제목 ──
	var title string
	if block, ok := values[BlockIDTitle]; ok {
		if action, ok := block[ActionTitle]; ok {
			title = strings.TrimSpace(action.Value)
		}
	}

	// ── 모드별 결과 생성 ──
	var resultBlocks []slack.Block

	switch state.Mode {
	case ModeShuffle:
		resultBlocks = buildShuffleResultBlocks(shuffled, invokerID, title)

	case ModeRoulette:
		countStr := "1"
		if block, ok := values[BlockIDCount]; ok {
			if action, ok := block[ActionCount]; ok {
				countStr = action.Value
			}
		}
		count, parseErr := strconv.Atoi(strings.TrimSpace(countStr))
		if parseErr != nil || count < 1 {
			return respondWithModalError(BlockIDCount, "뽑을 인원 수는 1 이상의 숫자를 입력해주세요")
		}
		if count > len(shuffled) {
			return respondWithModalError(BlockIDCount, fmt.Sprintf("대상이 %d명뿐입니다. %d 이하로 입력해주세요.", len(shuffled), len(shuffled)))
		}
		winners := shuffled[:count]
		resultBlocks = buildRouletteResultBlocks(winners, len(shuffled), count, invokerID, title)
	}

	// ── 결과 메시지 전송 ──
	_, _, err = app.slack.PostMessage(
		state.ResponseChannel,
		slack.MsgOptionBlocks(resultBlocks...),
	)
	if err != nil {
		log.Printf("[에러] 결과 메시지 전송 실패: %v", err)
		return respondWithModalError(BlockIDSourceType, "결과 메시지 전송에 실패했습니다. 잠시 후 다시 시도해주세요.")
	}

	log.Printf("[성공] %s 실행 완료 (mode=%s, total=%d, invoker=%s)", state.Mode, state.Mode, len(shuffled), invokerID)
	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
// 에러 응답

// 모달에 에러 표시 (View Submission 응답)
func respondWithModalError(blockID, message string) (events.LambdaFunctionURLResponse, error) {
	response := map[string]interface{}{
		"response_action": "errors",
		"errors": map[string]string{
			blockID: message,
		},
	}
	body, _ := json.Marshal(response)
	return events.LambdaFunctionURLResponse{
		StatusCode: 200,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       string(body),
	}, nil
}

// Slack에 에러 메시지 반환
func respondWithSlackError(message string) (events.LambdaFunctionURLResponse, error) {
	return events.LambdaFunctionURLResponse{
		StatusCode: 200,
		Headers:    map[string]string{"Content-Type": "text/plain; charset=utf-8"},
		Body:       "⚠️ " + message,
	}, nil
}

func respondWithHelpMessage(locale string) (events.LambdaFunctionURLResponse, error) {
	var help string
	switch {
	case strings.HasPrefix(locale, "ko"):
		help = strings.Join([]string{
			"*🎲 /shuffle 사용법*",
			"",
			"*기본*",
			"`/shuffle @A @B @C` — 셔플",
			"`/shuffle @here` — 이 채널 멤버 셔플",
			"`/shuffle @유저그룹` — 유저그룹 멤버 셔플",
			"`/shuffle N @A @B @C` — N명 룰렛",
			"`/shuffle N @here` — 이 채널에서 N명 룰렛",
			"",
			"*제외* — `--` 뒤에 멘션하면 제외 (여러 명 가능)",
			"`/shuffle @here -- @제외1 @제외2`",
			"",
			"*제목* — 멘션 앞에 텍스트를 붙이면 결과 제목",
			"`/shuffle 점심당번 @A @B @C`",
			"`/shuffle 리뷰어 2 @here`",
			"",
			"*입력 화면* — 인자 없이 입력하면 설정 화면이 열립니다",
			"`/shuffle`",
		}, "\n")
	case strings.HasPrefix(locale, "ja"):
		help = strings.Join([]string{
			"*🎲 /shuffle の使い方*",
			"",
			"*基本*",
			"`/shuffle @A @B @C` — シャッフル",
			"`/shuffle @here` — このチャンネルのメンバーをシャッフル",
			"`/shuffle @ユーザーグループ` — グループメンバーをシャッフル",
			"`/shuffle N @A @B @C` — N人をルーレット",
			"`/shuffle N @here` — このチャンネルからN人をルーレット",
			"",
			"*除外* — `--` の後にメンションすると除外（複数可）",
			"`/shuffle @here -- @除外1 @除外2`",
			"",
			"*タイトル* — メンションの前にテキストを付けると結果のタイトルに",
			"`/shuffle ランチ当番 @A @B @C`",
			"`/shuffle レビュアー 2 @here`",
			"",
			"*入力画面* — 引数なしで入力すると設定画面が開きます",
			"`/shuffle`",
		}, "\n")
	case strings.HasPrefix(locale, "zh"):
		help = strings.Join([]string{
			"*🎲 /shuffle 使用方法*",
			"",
			"*基本*",
			"`/shuffle @A @B @C` — 随机排序",
			"`/shuffle @here` — 随机排序本频道成员",
			"`/shuffle @用户组` — 随机排序用户组成员",
			"`/shuffle N @A @B @C` — 抽取N人",
			"`/shuffle N @here` — 从本频道抽取N人",
			"",
			"*排除* — 在 `--` 后面提及要排除的人（可多人）",
			"`/shuffle @here -- @排除1 @排除2`",
			"",
			"*标题* — 在提及前添加文字作为结果标题",
			"`/shuffle 午餐值班 @A @B @C`",
			"`/shuffle 审阅人 2 @here`",
			"",
			"*输入界面* — 不带参数直接输入即可打开设置界面",
			"`/shuffle`",
		}, "\n")
	default:
		help = strings.Join([]string{
			"*🎲 /shuffle usage*",
			"",
			"*Basic*",
			"`/shuffle @A @B @C` — shuffle",
			"`/shuffle @here` — shuffle channel members",
			"`/shuffle @usergroup` — shuffle group members",
			"`/shuffle N @A @B @C` — pick N (roulette)",
			"`/shuffle N @here` — pick N from channel",
			"",
			"*Exclude* — mention after `--` to exclude (multiple OK)",
			"`/shuffle @here -- @exclude1 @exclude2`",
			"",
			"*Title* — text before mentions becomes result title",
			"`/shuffle lunch duty @A @B @C`",
			"`/shuffle reviewer 2 @here`",
			"",
			"*Input form* — run without arguments to open the settings form",
			"`/shuffle`",
		}, "\n")
	}

	response := map[string]interface{}{
		"response_type": "ephemeral",
		"text":          help,
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
// 유틸리티

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-3] + "..."
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

	// Slash Command 또는 Interactive Component 구분
	if strings.Contains(bodyStr, "command=%2Fshuffle") || strings.Contains(bodyStr, "command=/shuffle") {
		log.Println("[요청] Slash Command 처리")
		return app.handleSlashCommand(bodyStr)
	}

	if strings.Contains(bodyStr, "payload=") {
		log.Println("[요청] Interactive Component 처리")
		return app.handleInteraction(bodyStr)
	}

	log.Printf("[무시] 알 수 없는 요청 타입")
	return events.LambdaFunctionURLResponse{StatusCode: 200}, nil
}

// ─────────────────────────────────────
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
	app.refreshUserCache()
}

func main() {
	lambda.Start(app.handler)
}

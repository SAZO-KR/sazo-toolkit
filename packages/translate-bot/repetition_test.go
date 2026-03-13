package main

import (
	"strings"
	"testing"
)

func TestNormalizeRepetition(t *testing.T) {
	tests := []struct {
		name          string
		input         string
		wantText      string
		wantMaxRepeat int
	}{
		{
			name:          "actual_explosion_case_あ×7",
			input:         "誕生日おめでとうございまあああああああす",
			wantText:      "誕生日おめでとうございまあああす",
			wantMaxRepeat: 7,
		},
		{
			name:          "multiple_repetitions_ー×6_！×5_ー×4",
			input:         "すごーーーーーーい！！！！！やばーーーーい",
			wantText:      "すごーーーい！！！やばーーーい",
			wantMaxRepeat: 6,
		},
		{
			name:          "korean_laughter_ㅋ×10",
			input:         "진짜 웃기다ㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋ",
			wantText:      "진짜 웃기다ㅋㅋㅋ",
			wantMaxRepeat: 10,
		},
		{
			name:          "emoji_repetition",
			input:         "嬉しい😭😭😭😭😭😭😭😭😭😭",
			wantText:      "嬉しい😭😭😭",
			wantMaxRepeat: 10,
		},
		{
			name:          "no_change_normal_text",
			input:         "こんにちは",
			wantText:      "こんにちは",
			wantMaxRepeat: 0,
		},
		{
			name:          "no_change_2_repeats",
			input:         "ああ、そうですか",
			wantText:      "ああ、そうですか",
			wantMaxRepeat: 0,
		},
		{
			name:          "no_change_3_repeats",
			input:         "おおお",
			wantText:      "おおお",
			wantMaxRepeat: 0,
		},
		{
			name:          "boundary_4_repeats",
			input:         "ああああ",
			wantText:      "あああ",
			wantMaxRepeat: 4,
		},
		{
			name:          "spaces_break_repetition",
			input:         "あ あ あ あ あ あ あ",
			wantText:      "あ あ あ あ あ あ あ",
			wantMaxRepeat: 0,
		},
		{
			name:          "empty_string",
			input:         "",
			wantText:      "",
			wantMaxRepeat: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotText, gotMax := normalizeRepetition(tt.input)
			if gotText != tt.wantText {
				t.Errorf("text: got %q, want %q", gotText, tt.wantText)
			}
			if gotMax != tt.wantMaxRepeat {
				t.Errorf("maxRepeat: got %d, want %d", gotMax, tt.wantMaxRepeat)
			}
		})
	}
}

func TestCapRepetition(t *testing.T) {
	tests := []struct {
		name      string
		input     string
		maxRepeat int
		want      string
	}{
		{
			name:      "cap_exploded_아×800",
			input:     "생일 축하합니다" + strings.Repeat("아", 800),
			maxRepeat: 7,
			want:      "생일 축하합니다" + strings.Repeat("아", 7),
		},
		{
			name:      "cap_exploded_mixed",
			input:     "생일 축하합니다" + strings.Repeat("아", 800) + strings.Repeat("a", 300) + "bc",
			maxRepeat: 7,
			want:      "생일 축하합니다" + strings.Repeat("아", 7) + strings.Repeat("a", 7) + "bc",
		},
		{
			name:      "no_cap_normal_text",
			input:     "생일 축하합니다",
			maxRepeat: 7,
			want:      "생일 축하합니다",
		},
		{
			name:      "no_cap_within_limit",
			input:     "아아아아아",
			maxRepeat: 7,
			want:      "아아아아아",
		},
		{
			name:      "skip_when_maxRepeat_below_3",
			input:     "아아아아아아아아아아",
			maxRepeat: 0,
			want:      "아아아아아아아아아아",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := capRepetition(tt.input, tt.maxRepeat)
			if got != tt.want {
				t.Errorf("got %q (len=%d), want %q (len=%d)",
					truncate(got, 50), len([]rune(got)),
					truncate(tt.want, 50), len([]rune(tt.want)))
			}
		})
	}
}

func TestEndToEnd_NormalizeAndCap(t *testing.T) {
	tests := []struct {
		name      string
		input     string
		fakeTrans string
		want      string
	}{
		{
			name:      "explosion_prevented",
			input:     "誕生日おめでとうございまあああああああす",
			fakeTrans: "생일 축하합니다" + strings.Repeat("아", 50),
			want:      "생일 축하합니다" + strings.Repeat("아", 7),
		},
		{
			name:      "normal_translation_untouched",
			input:     "誕生日おめでとうございまあああああああす",
			fakeTrans: "생일 축하합니다아아아",
			want:      "생일 축하합니다아아아",
		},
		{
			name:      "no_repetition_in_source",
			input:     "こんにちは",
			fakeTrans: "안녕하세요",
			want:      "안녕하세요",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, maxRepeat := normalizeRepetition(tt.input)
			got := capRepetition(tt.fakeTrans, maxRepeat)
			if got != tt.want {
				t.Errorf("got %q, want %q", truncate(got, 80), truncate(tt.want, 80))
			}
		})
	}
}

func truncate(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n]) + "..."
}

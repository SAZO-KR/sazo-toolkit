package main

// ─────────────────────────────────────
// 반복 문자 정규화 (4회 이상 연속 반복 → 3회로 축소, LLM 반복 폭발 방지)

func normalizeRepetition(text string) (string, int) {
	runes := []rune(text)
	var result []rune
	maxRepeat := 0
	i := 0
	for i < len(runes) {
		ch := runes[i]
		j := i + 1
		for j < len(runes) && runes[j] == ch {
			j++
		}
		count := j - i

		if count >= 4 {
			if count > maxRepeat {
				maxRepeat = count
			}
			result = append(result, ch, ch, ch)
		} else {
			result = append(result, runes[i:j]...)
		}
		i = j
	}

	return string(result), maxRepeat
}

func capRepetition(text string, maxRepeat int) string {
	if maxRepeat < 3 {
		return text
	}

	runes := []rune(text)
	var result []rune
	i := 0
	for i < len(runes) {
		ch := runes[i]
		j := i + 1
		for j < len(runes) && runes[j] == ch {
			j++
		}
		count := j - i

		if count > maxRepeat {
			for k := 0; k < maxRepeat; k++ {
				result = append(result, ch)
			}
		} else {
			result = append(result, runes[i:j]...)
		}
		i = j
	}

	return string(result)
}

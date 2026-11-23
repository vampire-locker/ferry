// Package i18n localizes helper messages without changing the JSON protocol.
package i18n

import (
	"embed"
	"encoding/json"
	"os"
	"strings"
)

//go:embed locales/*.json
var resources embed.FS

var messages = func() map[string]string {
	language := os.Getenv("FERRY_LANGUAGE")
	if language == "" {
		language = "zh-Hans"
	}
	data, err := resources.ReadFile("locales/" + language + ".json")
	if err != nil {
		base := strings.SplitN(language, "-", 2)[0]
		data, err = resources.ReadFile("locales/" + base + ".json")
	}
	if err != nil {
		return nil
	}
	var result map[string]string
	if json.Unmarshal(data, &result) != nil {
		return nil
	}
	return result
}()

// Text returns the development-language source if a translation is missing.
// Callers keep fmt formatting/error wrapping so %w semantics remain intact.
func Text(source string) string {
	if translated, ok := messages[source]; ok {
		return translated
	}
	return source
}

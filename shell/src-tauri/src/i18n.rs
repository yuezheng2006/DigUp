//! Native menus use the OS UI language; protocol keys and paths stay in English.
use std::sync::OnceLock;

pub fn is_chinese() -> bool {
    static CHINESE: OnceLock<bool> = OnceLock::new();
    *CHINESE.get_or_init(|| {
        #[cfg(windows)]
        {
            #[link(name = "kernel32")]
            extern "system" { fn GetUserDefaultUILanguage() -> u16; }
            // PRIMARYLANGID: Chinese is 0x04 (both simplified and traditional locales).
            return unsafe { GetUserDefaultUILanguage() } & 0x3ff == 0x04;
        }
        #[cfg(not(windows))]
        {
            for key in ["LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"] {
                if let Ok(value) = std::env::var(key) {
                    if !value.is_empty() { return chinese_locale(&value); }
                }
            }
            false
        }
    })
}

fn chinese_locale(locale: &str) -> bool {
    for language in locale.split(':') {
        let tag = language.to_lowercase().replace('_', "-");
        if tag == "zh" || tag.starts_with("zh-") { return true; }
        if tag == "en" || tag.starts_with("en-") || tag.starts_with("en.") { return false; }
    }
    false
}

pub fn tr<'a>(english: &'a str, chinese: &'a str) -> &'a str {
    if is_chinese() { chinese } else { english }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn language_priority_and_fallback() {
        assert!(chinese_locale("zh_CN.UTF-8"));
        assert!(chinese_locale("zh-TW"));
        assert!(chinese_locale("fr:zh_CN:en"));
        assert!(!chinese_locale("en_US:zh_CN"));
        assert!(!chinese_locale("C.UTF-8"));
    }
}

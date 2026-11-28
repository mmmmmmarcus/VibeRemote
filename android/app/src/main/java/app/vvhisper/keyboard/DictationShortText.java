package app.vvhisper.keyboard;

final class DictationShortText {
    static boolean skipsPolishing(String text) {
        int han = 0, words = 0; boolean inWord = false;
        for (int offset = 0; offset < text.length();) {
            int c = text.codePointAt(offset); offset += Character.charCount(c);
            if (c >= 0x3400 && c <= 0x4DBF || c >= 0x4E00 && c <= 0x9FFF || c >= 0xF900 && c <= 0xFAFF || c >= 0x20000 && c <= 0x2FA1F) { han++; inWord = false; }
            else if (Character.isAlphabetic(c) || Character.isDigit(c)) { if (!inWord) words++; inWord = true; }
            else if (!(inWord && (c == '\'' || c == 0x2019 || c == '-'))) inWord = false;
        }
        return han + words * 1.5 <= 6;
    }
}

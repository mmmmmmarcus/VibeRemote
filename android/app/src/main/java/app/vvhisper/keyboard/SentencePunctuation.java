package app.vvhisper.keyboard;

import android.icu.lang.UCharacter;
import java.util.Locale;

final class SentencePunctuation {
    private static final String TERMINALS = ".!?。！？…";
    private static final String CLOSERS = "\"'”’»）)]】》」』";

    static String apply(String text, boolean enabled) {
        int first = 0, last = text.length();
        while (first < last && UCharacter.isUWhiteSpace(text.codePointAt(first)))
            first += Character.charCount(text.codePointAt(first));
        while (last > first && UCharacter.isUWhiteSpace(text.codePointBefore(last)))
            last -= Character.charCount(text.codePointBefore(last));
        String trimmed = text.substring(first, last);
        if (trimmed.isEmpty() || trimmed.length() > 240 || trimmed.contains("://")
                || trimmed.contains("@") || trimmed.toLowerCase(Locale.ROOT).contains("www.")) return text;
        int[] scalars = trimmed.codePoints().toArray();
        if (scalars.length > 120) return text;
        boolean han = false, inWord = false;
        int words = 0;
        for (int c : scalars) {
            if (c >= 10 && c <= 13 || c == 0x85 || c == 0x2028 || c == 0x2029) return text;
            boolean word = !UCharacter.isUWhiteSpace(c);
            if (word && !inWord && ++words > 20) return text;
            inWord = word;
            han |= c >= 0x3400 && c <= 0x4dbf || c >= 0x4e00 && c <= 0x9fff
                    || c >= 0x20000 && c <= 0x323af;
        }
        if (han && scalars.length > 40) return text;
        int close = scalars.length;
        while (close > 0 && CLOSERS.indexOf(scalars[close - 1]) >= 0) close--;
        int end = close;
        while (end > 0 && TERMINALS.indexOf(scalars[end - 1]) >= 0) end--;
        if (enabled == (end < close)) return text;
        boolean hasWord = false;
        for (int i = 0; i < end; i++) {
            int c = scalars[i];
            hasWord |= Character.isLetterOrDigit(c) || Character.getType(c) == Character.OTHER_NUMBER
                    || Character.getType(c) == Character.LETTER_NUMBER;
            if (TERMINALS.indexOf(c) >= 0 && !(c == '.' && i > 0 && i + 1 < end
                    && Character.isDigit(scalars[i - 1]) && Character.isDigit(scalars[i + 1]))) return text;
        }
        if (!hasWord) return text;
        if (!enabled) while (end > 0 && UCharacter.isUWhiteSpace(scalars[end - 1])) end--;
        String terminal = enabled ? (han ? "。" : ".") : "";
        return new String(scalars, 0, end) + terminal + new String(scalars, close, scalars.length - close);
    }
}

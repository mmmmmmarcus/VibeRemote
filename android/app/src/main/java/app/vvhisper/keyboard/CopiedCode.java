package app.vvhisper.keyboard;

import java.util.Locale;
import java.util.regex.*;

final class CopiedCode {
    private static final Pattern TOKEN =
            Pattern.compile(
                    "(?<![A-Za-z0-9])([0-9]{3}[ -][0-9]{3}|[A-Za-z0-9]{4,8})(?![A-Za-z0-9])");

    static String extract(CharSequence source) {
        if (source == null || source.length() > 4096) return null;
        String text = source.toString().trim(), compact = text.replace(" ", "").replace("-", "");
        if (compact.matches("[a-zA-Z0-9]{4,8}") && compact.matches(".*[0-9].*")) return compact;
        if (!Pattern.compile("code|otp|pin|验证码|驗證碼|校验码|动态码|安全码|登录|登入")
                .matcher(text.toLowerCase(Locale.ROOT))
                .find()) return null;
        Matcher tokens = TOKEN.matcher(text);
        String code = null;
        while (tokens.find()) {
            String match = tokens.group(1).replace(" ", "").replace("-", "");
            if (!match.matches(".*[0-9].*")) continue;
            if (code != null && !code.equals(match)) return null;
            code = match;
        }
        return code;
    }
}

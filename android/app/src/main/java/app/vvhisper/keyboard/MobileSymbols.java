package app.vvhisper.keyboard;
import java.util.*;
final class MobileSymbols {
    static String chinese(String raw) {
        String ascii = ",.?!:;()[]\"'/-_~@#%&*+=^|";
        String[] local = {"，","。","？","！","：","；","（","）","【","】","「","」","、","—","＿","～","＠","＃","％","＆","＊","＋","＝","＾","｜"};
        int i = raw.length() == 1 ? ascii.indexOf(raw) : -1;
        return i >= 0 ? local[i] : raw;
    }
    static List<String> alternatives(String value) {
        String ascii = ",.?!:;()[]\"'/-_~@#%&*+=^|";
        String original = value;
        for (int i = 0; i < ascii.length(); i++) if (chinese(ascii.substring(i,i+1)).equals(value)) original = ascii.substring(i,i+1);
        String variants = switch (original) {
            case "." -> "… 。 · ．"; case "," -> "， 、 ‚"; case "?" -> "？ ¿"; case "!" -> "！ ¡";
            case "\"" -> "「 『 “ ” \""; case "'" -> "」 』 ‘ ’ '"; case "-" -> "— – − •";
            case "$", "¥", "€", "£" -> "$ ¥ € £ ₩ ₹";
            case "1" -> "¹ ₁ ½ ⅓ ¼"; case "2" -> "² ₂ ⅔"; case "3" -> "³ ₃ ¾";
            default -> original + " " + chinese(original);
        };
        LinkedHashSet<String> result = new LinkedHashSet<>(); result.add(value); result.add(original); result.addAll(Arrays.asList(variants.split(" ")));
        result.remove(""); return new ArrayList<>(result);
    }
}

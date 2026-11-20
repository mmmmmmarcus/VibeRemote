package app.vvhisper.keyboard;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;

import java.io.*;
import java.util.*;

/** Read-only SQLite lookups. The large asset is unpacked once on a worker thread. */
final class Candidates {
    private volatile SQLiteDatabase db;
    private final Set<String> english = new HashSet<>();

    void open(Context context) throws IOException {
        File dir = context.getNoBackupFilesDir();
        File file =
                new File(
                        dir, "pinyin-" + context.getApplicationInfo().sourceDir.hashCode() + ".db");
        if (!file.exists()) {
            File tmp = File.createTempFile("dict", ".tmp", dir);
            try (InputStream in = context.getAssets().open("pinyin.db");
                    OutputStream out = new FileOutputStream(tmp)) {
                byte[] block = new byte[65536];
                for (int n; (n = in.read(block)) != -1; ) out.write(block, 0, n);
            }
            if (!tmp.renameTo(file)) throw new IOException("Installing keyboard dictionary");
        }
        try (BufferedReader reader =
                new BufferedReader(
                        new InputStreamReader(context.getAssets().open("EnglishWords.txt")))) {
            for (String line; (line = reader.readLine()) != null; )
                if (!line.startsWith("#")) english.add(line.trim());
        }
        db =
                SQLiteDatabase.openDatabase(
                        file.getPath(),
                        null,
                        SQLiteDatabase.OPEN_READONLY | SQLiteDatabase.NO_LOCALIZED_COLLATORS);
        File[] old =
                dir.listFiles(
                        (d, n) ->
                                n.startsWith("pinyin-")
                                        && n.endsWith(".db")
                                        && !n.equals(file.getName()));
        if (old != null) for (File stale : old) stale.delete();
    }

    private List<String> exact(String spelling, int limit) {
        List<String> result = new ArrayList<>();
        try (Cursor c =
                db.rawQuery(
                        "SELECT word FROM words WHERE spelling=? ORDER BY weight DESC LIMIT ?",
                        new String[] {spelling, Integer.toString(limit)})) {
            while (c.moveToNext()) result.add(c.getString(0));
        }
        return result;
    }

    boolean isEnglish(String text) { return english.contains(text.toLowerCase(Locale.ROOT)); }
    String correctEnglish(String original) {
        String lower = original.toLowerCase(Locale.ROOT);
        Map<String, String> contractions = Map.of("im", "I'm", "ive", "I've", "ill", "I'll", "id", "I'd", "dont", "don't", "cant", "can't", "wont", "won't", "isnt", "isn't", "youre", "you're", "thats", "that's");
        if (contractions.containsKey(lower)) return contractions.get(lower);
        if (original.length() < 4 || original.length() > 32 || !original.matches("[a-zA-Z]+") || isEnglish(lower)
                || original.equals(original.toUpperCase(Locale.ROOT)) || db == null || !exact(lower, 1).isEmpty()) return original;
        String match = null;
        for (String word : english) if (oneSlip(lower, word)) {
            if (match != null) return original;
            match = word;
        }
        if (match == null) return original;
        return Character.isUpperCase(original.charAt(0)) ? Character.toUpperCase(match.charAt(0)) + match.substring(1) : match;
    }
    static boolean oneSlip(String a, String b) {
        if (Math.abs(a.length() - b.length()) > 1 || a.equals(b)) return false;
        for (int i = 0; i < a.length(); i++) {
            if ((a.substring(0, i) + a.substring(i + 1)).equals(b)) return true;
            if (i + 1 < a.length() && (a.substring(0, i) + a.charAt(i + 1) + a.charAt(i) + a.substring(i + 2)).equals(b)) return true;
        }
        if (a.length() < b.length()) return oneSlip(b, a);
        if (a.length() != b.length()) return false;
        int differences = 0;
        for (int i = 0; i < a.length(); i++) if (a.charAt(i) != b.charAt(i)) differences++;
        return differences == 1;
    }
    List<String> lookup(String spelling) {
        if (db == null) return Collections.singletonList(spelling);
        List<String> words = exact(spelling, 100);
        if (words.isEmpty() && spelling.length() >= 4 && spelling.length() <= 32 && !english.contains(spelling)) {
            // Try bounded repeated-key and transposition repairs before segmentation.
            for (int i = 0, attempts = 0; i + 1 < spelling.length() && attempts < 8; i++, attempts++) {
                String fixed = spelling.charAt(i) == spelling.charAt(i + 1)
                    ? spelling.substring(0, i) + spelling.substring(i + 1)
                    : spelling.substring(0, i) + spelling.charAt(i + 1) + spelling.charAt(i) + spelling.substring(i + 2);
                for (String word : exact(fixed, 3)) if (!words.contains(word)) words.add(word);
                if (words.size() >= 3) break;
            }
        }
        if (words.isEmpty() && !english.contains(spelling)) {
            StringBuilder phrase = new StringBuilder();
            int start = 0;
            while (start < spelling.length()) {
                int end = Math.min(spelling.length(), start + 18);
                List<String> next = Collections.emptyList();
                while (end > start && (next = exact(spelling.substring(start, end), 1)).isEmpty())
                    end--;
                if (end == start) break;
                phrase.append(next.get(0));
                start = end;
            }
            if (start == spelling.length()) words.add(phrase.toString());
        }
        if (words.isEmpty() || english.contains(spelling)) words.add(spelling);
        return words;
    }

    List<String> completions(String prefix) {
        if (db == null) return Collections.emptyList();
        String lower = prefix.toLowerCase(Locale.ROOT);
        ArrayList<String> matches = new ArrayList<>();
        for (String word : english)
            if (word.startsWith(lower) && !word.equals(lower)) matches.add(word);
        matches.sort(
                Comparator.comparingInt(String::length).thenComparing(Comparator.naturalOrder()));
        return matches.subList(0, Math.min(2, matches.size()));
    }

    void close() {
        if (db != null) db.close();
    }
}

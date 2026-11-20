package app.vvhisper.keyboard;

import org.junit.Test;
import static org.junit.Assert.assertEquals;

public class SentencePunctuationTest {
    @Test public void shortSentences() {
        for (String[] row : new String[][] {
            {"Hello", "Hello", "Hello."},
            {"Hello.", "Hello", "Hello."},
            {"Are you ready?!", "Are you ready", "Are you ready?!"},
            {"Yes, please!", "Yes, please", "Yes, please!"},
            {"你好", "你好", "你好。"},
            {"你好！", "你好", "你好！"},
            {"“Hello!”", "“Hello”", "“Hello!”"},
            {"“Hello”", "“Hello”", "“Hello.”"},
            {"Version 2.0.", "Version 2.0", "Version 2.0."},
            {"", "", ""},
            {"...", "...", "..."},
        }) {
            assertEquals(row[1], SentencePunctuation.apply(row[0], false));
            assertEquals(row[2], SentencePunctuation.apply(row[0], true));
        }
    }

    @Test public void bypassAndBoundaries() {
        for (String text : new String[] {"First sentence. Second sentence.", "第一句。第二句。",
                "First\nSecond.", "Ask Dr. Smith.", "Visit example.com.", "https://example.com/path",
                "a@example.com", "a".repeat(121) + ".", "word ".repeat(21) + "end.", "中".repeat(41) + "。"}) {
            assertEquals(text, SentencePunctuation.apply(text, false));
            assertEquals(text, SentencePunctuation.apply(text, true));
        }
        for (String text : new String[] {"a".repeat(119), "中".repeat(39), "a ".repeat(19) + "a",
                "𠀀".repeat(39)}) {
            assertEquals(text, SentencePunctuation.apply(text + ".", false));
        }
    }
}

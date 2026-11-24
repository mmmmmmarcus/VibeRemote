package app.vvhisper.keyboard;

import android.Manifest;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.res.*;
import android.graphics.Typeface;
import android.graphics.drawable.*;
import android.inputmethodservice.InputMethodService;
import android.os.*;
import android.text.InputType;
import android.view.*;
import android.view.inputmethod.*;
import android.widget.*;

import java.util.*;
import java.util.concurrent.*;

public final class KeyboardService extends InputMethodService {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Candidates dictionary = new Candidates();
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private LinearLayout board, strip, row;
    private FrameLayout floatingFrame;
    private AlphabetKeys alphabet;
    private View letterDelete, compactDelete;
    private float floatOffsetX, floatOffsetY;
    private ScrollView expandedPanel;
    private View deleteKey, returnKey;
    private boolean chinese,
            mini,
            shifted,
            caps,
            symbols,
            more,
            secure,
            numeric,
            phone,
            expanded,
            plainLatin;
    private boolean emoji, numericPage;
    private String englishWord = "";
    private long lastShift, voiceId;
    private int surface, keyColor, special, ink;
    private String displaced = "";
    private String spelling = "", notice = "", preview = "", deleted = "";
    private List<String> choices = Collections.emptyList();
    private int autofillGeneration;
    private final ArrayList<View> autofillChips = new ArrayList<>();
    private Dictation voice;
    private PendingDictation pending;
    private okhttp3.Call polishCall;
    private boolean sendAfter, translateAfter, shortcutsExpanded;
    private View languageKey;
    private long lastSpace;
    private String spaceBefore = "", spaceAfter = "";
    private long copiedCodeAt;
    private String copiedCode = "";
    private ClipboardManager.OnPrimaryClipChangedListener clipListener;
    private ClipboardHistory clipboardHistory;
    private InputConnection emojiOwner;
    private String emojiBefore = "", emojiAfter = "";
    private float voiceLevel;
    private long lastMeter;
    private String typedEnglish = "", correctionOriginal = "", correctionResult = "", correctionAfter = "";
    private int restorePosition = -1, selectionStart = -1, selectionEnd = -1;
    private String restoreBefore = "", restoreAfter = "";
    private final Runnable timeout =
            () -> {
                if (voice != null) {
                    cancelVoice(true);
                    message("Dictation timed out");
                }
            };
    private final Runnable clearNotice =
            () -> {
                notice = "";
                refreshStrip();
            };

    private SharedPreferences prefs() {
        return getSharedPreferences("keyboard", 0);
    }

    private InputConnection editor() {
        return getCurrentInputConnection();
    }

    private int dp(float n) {
        return Math.round(n * getResources().getDisplayMetrics().density);
    }

    @Override
    public void onCreate() {
        super.onCreate();
        clipboardHistory = new ClipboardHistory(this);
        clipListener = () -> {
            copiedCode = "";
            if (!isInputViewShown() || secure) return;
            ClipData clip = getSystemService(ClipboardManager.class).getPrimaryClip();
            String copied = ClipboardHistory.textFrom(clip);
            clipboardHistory.record(copied);
            if (copied != null) {
                String code = CopiedCode.extract(copied);
                if (code != null) { copiedCode = code; copiedCodeAt = SystemClock.uptimeMillis(); }
            }
            refreshStrip();
            main.postDelayed(() -> { if (SystemClock.uptimeMillis() - copiedCodeAt >= 120000) { copiedCode = ""; refreshStrip(); } }, 120000);
        };
        getSystemService(ClipboardManager.class).addPrimaryClipChangedListener(clipListener);
        worker.execute(
                () -> {
                    try {
                        dictionary.open(this);
                        main.post(
                                () -> {
                                    if (!spelling.isEmpty()) compose();
                                });
                    } catch (Exception e) {
                        main.post(() -> message("Pinyin dictionary unavailable"));
                    }
                });
    }

    @Override
    public void onDestroy() {
        cancelVoice(false);
        main.removeCallbacksAndMessages(null);
        worker.execute(dictionary::close);
        worker.shutdown();
        getSystemService(ClipboardManager.class).removePrimaryClipChangedListener(clipListener);
        super.onDestroy();
    }

    @Override
    public boolean onEvaluateFullscreenMode() {
        return false;
    }

    @Override
    public View onCreateInputView() {
        board = new KeyboardBoard(this, this::setCompact);
        board.setOrientation(LinearLayout.VERTICAL);
        board.setOnApplyWindowInsetsListener(
                (v, insets) -> {
                    reserveNavigationSpace(insets);
                    return insets;
                });
        board.post(() -> reserveNavigationSpace(board.getRootWindowInsets()));
        render();
        if (!floating()) {
            floatingFrame = null;
            return board;
        }
        // A phone in landscape keeps the host editor at its normal size.
        floatingFrame = new FrameLayout(this);
        floatingFrame.setClipChildren(false);
        floatingFrame.setClipToPadding(false);
        FrameLayout.LayoutParams panel =
                new FrameLayout.LayoutParams(dp(324), -2, Gravity.RIGHT | Gravity.BOTTOM);
        panel.rightMargin = dp(55);
        panel.bottomMargin = dp(63.5f);
        floatingFrame.addView(board, panel);
        getWindow()
                .getWindow()
                .setBackgroundDrawable(new ColorDrawable(android.graphics.Color.TRANSPARENT));
        return floatingFrame;
    }

    @Override
    public void onComputeInsets(Insets out) {
        super.onComputeInsets(out);
        if (!floating() || floatingFrame == null || !board.isShown()) return;
        int[] where = new int[2];
        board.getLocationInWindow(where);
        out.contentTopInsets =
                out.visibleTopInsets = getWindow().getWindow().getDecorView().getHeight();
        out.touchableInsets = Insets.TOUCHABLE_INSETS_REGION;
        out.touchableRegion.set(
                where[0], where[1], where[0] + board.getWidth(), where[1] + board.getHeight());
    }

    @Override
    public void onStartInput(EditorInfo info, boolean restarting) {
        super.onStartInput(info, restarting);
        closeVoice();
        clearAutofill();
        spelling = "";
        choices = Collections.emptyList();
        deleted = "";
        notice = "";
        expanded = false;
        selectionStart = info.initialSelStart;
        selectionEnd = info.initialSelEnd;
        int type = info.inputType & InputType.TYPE_MASK_CLASS;
        int variation = info.inputType & InputType.TYPE_MASK_VARIATION;
        numeric = type == InputType.TYPE_CLASS_NUMBER || type == InputType.TYPE_CLASS_DATETIME;
        phone = type == InputType.TYPE_CLASS_PHONE;
        secure =
                (type == InputType.TYPE_CLASS_TEXT
                                && (variation == InputType.TYPE_TEXT_VARIATION_PASSWORD
                                        || variation
                                                == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                                        || variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD))
                        || (numeric && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        plainLatin =
                secure
                        || variation == InputType.TYPE_TEXT_VARIATION_URI
                        || variation == InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
                        || variation == InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS;
        chinese = prefs().getBoolean("chinese", Locale.getDefault().getLanguage().equals("zh"));
        mini = prefs().getBoolean("mini", false);
        caps = symbols = more = emoji = numericPage = false;
        shortcutsExpanded = false; lastSpace = 0; typedEnglish = correctionOriginal = correctionResult = "";
        englishWord = "";
        shifted =
                !plainLatin
                        && !chinese
                        && editor() != null
                        && editor().getCursorCapsMode(info.inputType) != 0;
    }

    @Override
    public void onStartInputView(EditorInfo info, boolean restarting) {
        super.onStartInputView(info, restarting);
        render();
    }

    @Override
    public void onFinishInputView(boolean finishing) {
        if (alphabet != null) alphabet.setCompact(mini, false);
        cancelVoice(false);
        clearAutofill();
        finishSpelling(false);
        deleted = "";
        main.removeCallbacks(clearNotice);
        super.onFinishInputView(finishing);
    }

    @Override
    public void onFinishInput() {
        cancelVoice(false);
        finishSpelling(false);
        super.onFinishInput();
    }

    @Override
    public void onCurrentInputMethodSubtypeChanged(InputMethodSubtype sub) {
        super.onCurrentInputMethodSubtypeChanged(sub);
        if (sub != null) {
            finishSpelling(true);
            chinese = sub.getLanguageTag().startsWith("zh");
            prefs().edit().putBoolean("chinese", chinese).apply();
            render();
        }
    }

    @Override
    public void onUpdateSelection(int os, int oe, int ns, int ne, int cs, int ce) {
        super.onUpdateSelection(os, oe, ns, ne, cs, ce);
        selectionStart = ns;
        selectionEnd = ne;
        if (!deleted.isEmpty() && (ns != restorePosition || ne != ns)) deleted = "";
        if (pending != null) {
            if (cs < 0 || ns != ne || ne != ce || !pending.owns(editor())) cancelVoice(true);
            return;
        }
        if (os == ns && oe == ne) return;
        String prefix = englishPrefix();
        if (!englishWord.equals(prefix)) {
            englishWord = prefix;
            refreshStrip();
        }
        if ((voice != null || !spelling.isEmpty()) && (cs < 0 || ns != ce || ne != ce)) {
            cancelVoice(true);
            if (editor() != null) editor().finishComposingText();
            spelling = "";
            choices = Collections.emptyList();
            expanded = false;
            refreshStrip();
        }
    }

    private String englishPrefix() {
        EditorInfo i = getCurrentInputEditorInfo();
        if (i == null
                || editor() == null
                || zh()
                || plainLatin
                || secure
                || numeric
                || phone
                || symbols
                || emoji
                || mini
                || voice != null
                || selectionStart != selectionEnd
                || (i.inputType & InputType.TYPE_MASK_CLASS) != InputType.TYPE_CLASS_TEXT
                || (i.inputType & InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS) != 0) return "";
        CharSequence before = editor().getTextBeforeCursor(40, 0);
        if (before == null) return "";
        int start = before.length();
        while (start > 0) {
            char c = before.charAt(start - 1);
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) break;
            start--;
        }
        return start == 0 && before.length() == 40
                ? ""
                : before.subSequence(start, before.length()).toString();
    }

    private boolean zh() {
        return chinese && !plainLatin;
    }

    private void reserveNavigationSpace(WindowInsets insets) {
        if (board == null || insets == null) return;
        int bottom =
                Build.VERSION.SDK_INT >= 30
                        ? insets.getInsets(WindowInsets.Type.navigationBars()).bottom
                        : insets.getStableInsetBottom();
        board.setPadding(
                dp(mini ? 8 : floating() ? 6 : 2),
                dp(mini ? 8 : 0),
                dp(mini ? 8 : floating() ? 6 : 2),
                floating() ? 0 : dp(29.67f) + bottom);
    }

    private void render() {
        if (board == null) return;
        renderKeys();
        if (floating()) addFloatingNavigation();
    }

    private void addFloatingNavigation() {
        LinearLayout nav = new LinearLayout(this);
        nav.setGravity(Gravity.CENTER_VERTICAL);
        board.addView(nav, -1, dp(44));
        TextView hide = tile("⌄", "Hide keyboard", 24);
        hide.setOnClickListener(v -> requestHideSelf(0));
        nav.addView(hide, dp(52), -1);
        FrameLayout grip = new FrameLayout(this);
        grip.setContentDescription("Move keyboard");
        View bar = new View(this);
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(ink);
        shape.setCornerRadius(dp(8));
        bar.setBackground(shape);
        bar.setAlpha(.6f);
        grip.addView(bar, new FrameLayout.LayoutParams(dp(72), dp(4), Gravity.CENTER));
        nav.addView(grip, new LinearLayout.LayoutParams(0, -1, 1));
        grip.setOnTouchListener(
                (v, event) -> {
                    if (floatingFrame == null) return false;
                    if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
                        floatOffsetX = event.getRawX() - board.getTranslationX();
                        floatOffsetY = event.getRawY() - board.getTranslationY();
                    } else if (event.getActionMasked() == MotionEvent.ACTION_MOVE) {
                        board.setTranslationX(
                                Math.max(
                                        -board.getLeft(),
                                        Math.min(
                                                floatingFrame.getWidth() - board.getRight(),
                                                event.getRawX() - floatOffsetX)));
                        board.setTranslationY(
                                Math.max(
                                        -board.getTop(),
                                        Math.min(
                                                floatingFrame.getHeight() - board.getBottom(),
                                                event.getRawY() - floatOffsetY)));
                        floatingFrame.requestLayout();
                    }
                    return true;
                });
        ImageButton picker = new ImageButton(this);
        picker.setBackgroundColor(0);
        picker.setImageResource(R.drawable.globe);
        picker.setColorFilter(ink);
        picker.setContentDescription("Choose keyboard");
        picker.setOnClickListener(
                v -> getSystemService(InputMethodManager.class).showInputMethodPicker());
        nav.addView(picker, dp(52), -1);
    }

    private void renderKeys() {
        boolean dark =
                (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
                        == Configuration.UI_MODE_NIGHT_YES;
        Window window = getWindow().getWindow();
        if (Build.VERSION.SDK_INT >= 30 && window.getInsetsController() != null) {
            WindowInsetsController controller = window.getInsetsController();
            int light = WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
            controller.setSystemBarsAppearance(dark ? 0 : light, light);
            if (Build.VERSION.SDK_INT >= 35) {
                if (floating()) controller.hide(WindowInsets.Type.captionBar());
                else controller.show(WindowInsets.Type.captionBar());
            }
        } else {
            window.getDecorView()
                    .setSystemUiVisibility(dark ? 0 : View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        }
        surface = dark ? 0xff1f1f1f : 0xffeeeeee;
        keyColor = dark ? 0xff393939 : 0xffffffff;
        special = dark ? 0xff474747 : 0xffd4d4d4;
        ink = dark ? 0xffe2e2e2 : 0xff1b1b1b;
        if (Build.VERSION.SDK_INT >= 34) {
            surface =
                    getColor(
                            dark
                                    ? android.R.color.system_surface_container_dark
                                    : android.R.color.system_surface_container_light);
            keyColor =
                    getColor(
                            dark
                                    ? android.R.color.system_surface_bright_dark
                                    : android.R.color.system_surface_container_lowest_light);
            ink =
                    getColor(
                            dark
                                    ? android.R.color.system_on_surface_dark
                                    : android.R.color.system_on_surface_light);
        }
        if (Build.VERSION.SDK_INT >= 31) {
            int high = getColor(android.R.color.system_neutral1_100);
            int low = getColor(android.R.color.system_neutral1_200);
            special =
                    dark
                            ? getColor(android.R.color.system_neutral1_700)
                            : android.graphics.Color.rgb(
                                    (android.graphics.Color.red(high)
                                                    + android.graphics.Color.red(low))
                                            / 2,
                                    (android.graphics.Color.green(high)
                                                    + android.graphics.Color.green(low))
                                            / 2,
                                    (android.graphics.Color.blue(high)
                                                    + android.graphics.Color.blue(low))
                                            / 2);
        }
        board.removeAllViews();
        alphabet = null;
        expandedPanel = null;
        deleteKey = returnKey = languageKey = null;
        GradientDrawable backdrop = new GradientDrawable();
        backdrop.setColor(surface);
        backdrop.setCornerRadius(floating() ? dp(20) : 0);
        board.setBackground(backdrop);
        board.setClipToOutline(floating());
        board.setElevation(floating() ? dp(4) : 0);
        board.setPadding(dp(floating() ? 6 : 2), 0, dp(floating() ? 6 : 2), 0);
        reserveNavigationSpace(board.getRootWindowInsets());
        strip = new LinearLayout(this);
        strip.setGravity(Gravity.CENTER_VERTICAL);
        board.addView(strip, -1, dp(48));
        refreshStrip();
        if (mini && !symbols && !emoji && !numericPage && !numeric && !phone) {
            strip.setVisibility(View.GONE);
            board.setPadding(dp(8), dp(8), dp(8), board.getPaddingBottom());
            newRow();
            function("↗", "Full keyboard", 1, () -> setCompact(false));
            function("●", "Hold to dictate", 6, this::toggleVoice);
            deleteButton(); actionKey();
            return;
        }
        if (expanded && !spelling.isEmpty()) {
            candidatePanel();
            return;
        }
        if (numericPage) {
            renderNumericPage();
            return;
        }
        if (numeric || phone) {
            String[] groups = {"123", "456", "789"};
            String[] extras = phone ? new String[] {"+", "*", "#"} : new String[] {"-", ".", ","};
            for (int i = 0; i < groups.length; i++) {
                newRow();
                chars(groups[i]);
                character(extras[i]);
            }
            newRow();
            deleteButton();
            character("0");
            actionKey();
            return;
        }
        if (emoji) {
            strip.setVisibility(View.GONE);
            NativeEmojiPanel panel = new NativeEmojiPanel(this, ink, () -> {
                emojiOwner = editor(); emojiBefore = contextText(true); emojiAfter = contextText(false);
            }, glyph -> {
                if (editor() == emojiOwner && emojiBefore.equals(contextText(true)) && emojiAfter.equals(contextText(false))) {
                    editor().commitText(glyph, 1); KeyFeedback.play(board, HapticFeedbackConstants.KEYBOARD_TAP);
                }
            }, () -> { emoji = false; render(); }, this::erase);
            board.addView(panel, -1, dp(250)); return;
        } else if (symbols) {
            newRow();
            chars(more ? "~`|•√π÷×§∆" : "1234567890");
            newRow();
            chars(more ? "€¥$¢^°={}\\" : "@#£_&-+()/");
            newRow();
            function(
                    more ? "?123" : "=\\<",
                    "More symbols",
                    1.5f,
                    () -> {
                        more = !more;
                        render();
                    });
            chars(more ? "%©®™✓[]" : zh() ? "＊「」：；！？" : "*\"':;!?");
            deleteButton();
        } else {
            newRow();
            letterGroups("qwert", "yuiop");
            newRow();
            spacer(.5f);
            letterGroups("asdfg", "hjkl");
            spacer(.5f);
            newRow();
            shiftButton();
            letterGroups("zxcv", "bnm");
            deleteButton();
        }
        newRow();
        function(
                symbols || emoji ? "ABC" : "?123",
                "Letters or symbols",
                1.5f,
                () -> {
                    finishSpelling(true);
                    symbols = !emoji && !symbols;
                    emoji = false;
                    render();
                });
        if (symbols || plainLatin) {
            character(symbols && more ? "<" : zh() ? "，" : ",");
        } else {
            function(zh() ? "中" : "EN", "Switch typing language", 1f, this::switchLanguage);
            languageKey = row.getChildAt(row.getChildCount() - 1);
        }
        if (symbols)
            function(
                    "12\n34",
                    "Numeric keypad",
                    1f,
                    () -> {
                        numericPage = !numericPage;
                        render();
                    });
        else if (!plainLatin)
            function(
                    "",
                    "Emoji",
                    1f,
                    () -> {
                        finishSpelling(true);
                        emoji = !emoji;
                        render();
                    });
        if (wideLayout()) {
            function("", "Space", 2f, this::space);
            spacer(2);
            function("", "Space", 2f, this::space);
        } else function(zh() ? "简体拼音" : "", "Space", plainLatin ? 5f : 4f, this::space);
        character(symbols && more ? ">" : zh() ? "。" : ".");
        actionKey();

    }

    private void bindAlphabet() {
        KeyboardRow top = (KeyboardRow) board.getChildAt(1);
        KeyboardRow home = (KeyboardRow) board.getChildAt(2);
        KeyboardRow letters = (KeyboardRow) board.getChildAt(3);
        letterDelete = deleteKey;
        newRow();
        shiftButton();
        function("●", "Hold to dictate", wideLayout() ? 9f : 7f, this::toggleVoice);
        deleteButton();
        compactDelete = deleteKey;
        KeyboardRow dictate = (KeyboardRow) row;
        board.removeView(dictate);
        board.removeViews(1, 3);
        alphabet = new AlphabetKeys(this, top, home, letters, dictate, mini);
        board.addView(alphabet, 1, new LinearLayout.LayoutParams(-1, -2));
        deleteKey = mini ? compactDelete : letterDelete;
    }

    private void setCompact(boolean compact) {
        if (numeric || phone || mini == compact) return;
        cancelVoice(false); finishSpelling(true);
        emoji = numericPage = symbols = false;
        mini = compact; prefs().edit().putBoolean("mini", mini).apply();
        if (android.animation.ValueAnimator.areAnimatorsEnabled()) {
            android.transition.AutoTransition transition = new android.transition.AutoTransition();
            transition.setDuration(220); android.transition.TransitionManager.beginDelayedTransition(board, transition);
        }
        render();
    }

    private void renderNumericPage() {
        LinearLayout group = new LinearLayout(this);
        float pitch = floating() ? 48 : 58.98f;
        board.addView(group, -1, dp(3 * pitch));
        LinearLayout operations = new LinearLayout(this);
        operations.setOrientation(LinearLayout.VERTICAL);
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(special);
        shape.setCornerRadius(dp(7));
        operations.setBackground(shape);
        // Give the entire operator column one continuous keycap.
        FrameLayout slot = new FrameLayout(this);
        group.addView(slot, new LinearLayout.LayoutParams(0, -1, 1.5f));
        FrameLayout.LayoutParams inset = new FrameLayout.LayoutParams(-1, -1);
        inset.setMargins(dp(2.33f), dp(6), dp(2.33f), 0);
        slot.addView(operations, inset);
        for (String op : new String[] {"+", "-", "*", "/"}) {
            TextView key = tile(op, op, 16);
            key.setOnClickListener(v -> type(op, false));
            operations.addView(key, new LinearLayout.LayoutParams(-1, 0, 1));
        }
        LinearLayout digits = new LinearLayout(this);
        digits.setOrientation(LinearLayout.VERTICAL);
        group.addView(digits, new LinearLayout.LayoutParams(0, -1, 8.5f));
        for (int i = 0; i < 3; i++) {
            row = new KeyboardRow(this);
            digits.addView(row, new LinearLayout.LayoutParams(-1, 0, 1));
            for (int j = 1; j <= 3; j++) {
                String n = Integer.toString(3 * i + j);
                addKey(n, n, 7f / 3, keyColor, () -> type(n, false), "symbol");
            }
            if (i == 0) function("%", "Percent", 1.5f, () -> type("%", false));
            else if (i == 1) addKey("␣", "Space", 1.5f, special, this::space, "Space");
            else deleteButton();
            for (int j = 0; j < row.getChildCount(); j++) {
                LinearLayout.LayoutParams lp =
                        (LinearLayout.LayoutParams) row.getChildAt(j).getLayoutParams();
                lp.setMargins(dp(2.33f), dp(6), dp(2.33f), 0);
            }
        }
        newRow();
        function(
                "ABC",
                "Letters or symbols",
                1.5f,
                () -> {
                    numericPage = symbols = more = false;
                    render();
                });
        function(",", ",", 1, () -> type(",", false));
        addKey(
                "!?#",
                "Symbols",
                4f / 3,
                keyColor,
                () -> {
                    numericPage = more = false;
                    render();
                },
                "Symbols");
        addKey("0", "0", 7f / 3, keyColor, () -> type("0", false), "symbol");
        addKey("=", "=", 4f / 3, keyColor, () -> type("=", false), "symbol");
        function(".", ".", 1, () -> type(".", false));
        actionKey();
    }

    private boolean floating() {
        Configuration config = getResources().getConfiguration();
        return config.orientation == Configuration.ORIENTATION_LANDSCAPE
                && config.smallestScreenWidthDp < 600;
    }

    private boolean wideLayout() {
        return !floating() && getResources().getConfiguration().screenWidthDp >= 700;
    }

    private void letterGroups(String left, String right) {
        chars(left);
        if (wideLayout()) spacer(2);
        chars(right);
    }

    private void switchLanguage() {
        englishWord = "";
        finishSpelling(true);
        chinese = !chinese;
        prefs().edit().putBoolean("chinese", chinese).apply();
        shifted = caps = false;
        render();
    }

    private void newRow() {
        row = new KeyboardRow(this);
        float pitch = floating() ? 48 : 58.98f;
        int n = board.getChildCount() - 1;
        board.addView(
                row,
                -1,
                (int) ((n + 1) * pitch * getResources().getDisplayMetrics().density)
                        - (int) (n * pitch * getResources().getDisplayMetrics().density));
    }

    private void spacer(float w) {
        row.addView(new View(this), new LinearLayout.LayoutParams(0, -1, w));
    }

    private void chars(String s) {
        s.codePoints().forEach(c -> character(new String(Character.toChars(c))));
    }

    private void character(String raw) {
        if (symbols && zh()) raw = MobileSymbols.chinese(raw);
        boolean letter = Character.isLetter(raw.codePointAt(0)) && !symbols;
        String label = letter && (shifted || caps) ? raw.toUpperCase(Locale.ROOT) : raw;
        boolean punctuation = board.getChildCount() == 5 && (",，.。<>".contains(raw));
        addKey(
                label,
                label,
                1,
                punctuation ? special : keyColor,
                () -> type(label, letter),
                letter ? "letter" : "symbol");
    }

    private void shiftButton() {
        function(
                caps ? "⇪" : "⇧",
                "Shift",
                1.5f,
                () -> {
                    long now = SystemClock.uptimeMillis();
                    if (!caps && shifted && now - lastShift < 420) caps = true;
                    else {
                        shifted = !shifted;
                        caps = false;
                    }
                    lastShift = now;
                    render();
                });
    }

    private void deleteButton() {
        deleteKey = function("⌫", "Delete", 1.5f, this::erase);
    }

    private void actionKey() {
        returnKey =
                addKey(
                        actionLabel(),
                        "Enter, " + actionLabel(),
                        1.5f,
                        special,
                        this::enter,
                        "action");
    }

    private String actionLabel() {
        EditorInfo i = getCurrentInputEditorInfo();
        if (i == null || (i.imeOptions & EditorInfo.IME_FLAG_NO_ENTER_ACTION) != 0) return "↵";
        if (i.actionLabel != null) return i.actionLabel.toString();
        switch (i.imeOptions & EditorInfo.IME_MASK_ACTION) {
            case EditorInfo.IME_ACTION_GO:
                return "Go";
            case EditorInfo.IME_ACTION_NEXT:
                return "Next";
            case EditorInfo.IME_ACTION_PREVIOUS:
                return "Prev";
            case EditorInfo.IME_ACTION_DONE:
                return "Done";
            case EditorInfo.IME_ACTION_SEARCH:
                return "Search";
            case EditorInfo.IME_ACTION_SEND:
                return "Send";
            default:
                return "↵";
        }
    }

    private TextView function(String label, String desc, float w, Runnable click) {
        return addKey(
                label,
                desc,
                w,
                desc.equals("Space") || desc.equals("Emoji") || desc.equals("Numeric keypad")
                        ? keyColor
                        : special,
                click,
                desc);
    }

    private TextView addKey(
            String label, String desc, float w, int color, Runnable click, String kind) {
        int icon =
                switch (desc) {
                    case "Shift" -> shifted || caps ? R.drawable.shift_on : R.drawable.shift_off;
                    case "Delete" -> R.drawable.backspace;
                    case "Enter, ↵" -> R.drawable.enter_key;
                    case "Enter, Search" -> R.drawable.search_key;
                    case "Emoji" -> R.drawable.face;
                    case "Hold to dictate" -> R.drawable.mic;
                    default -> 0;
                };
        int index =
                kind.equals("letter") ? "qwertyuiop".indexOf(label.toLowerCase(Locale.ROOT)) : -1;
        String hint = index >= 0 ? String.valueOf((index + 1) % 10) : "";
        int size = kind.equals("letter") || kind.equals("symbol") ? (floating() ? 24 : 27) : 16;
        if (desc.equals("Letters or symbols")) size = 18;
        TextView key = new Keycap(this, label, icon, hint, ink, size, kind.equals("letter") || kind.equals("symbol"));
        key.setContentDescription(desc);
        key.setFocusable(true);
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(color);
        shape.setCornerRadius(
                dp(kind.equals("action") || desc.equals("Letters or symbols") ? 28 : 7));
        key.setBackground(new RippleDrawable(ColorStateList.valueOf(0x33888888), shape, null));
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(0, -1, w);
        p.setMargins(dp(3), dp(floating() ? 4.5f : 6), dp(3), dp(floating() ? 4.5f : 6));
        row.addView(key, p);
        key.setOnClickListener(
                v -> {
                    if (voice != null || pending != null) cancelVoice(true);
                    click.run();
                });
        key.setOnTouchListener(new KeyGesture(key, kind));
        return key;
    }

    private TextView tile(String label, String desc, int sp) {
        TextView v = new TextView(this);
        v.setText(label);
        v.setTextSize(sp);
        v.setGravity(Gravity.CENTER);
        v.setSingleLine();
        v.setTextColor(ink);
        v.setContentDescription(desc);
        v.setFocusable(true);
        return v;
    }

    @Override public boolean onKeyDown(int keyCode, KeyEvent event) {
        // Hardware typing/deletion must invalidate polish before the host edits.
        if (pending != null && !KeyEvent.isModifierKey(keyCode)) cancelVoice(true);
        return super.onKeyDown(keyCode, event);
    }

    private void type(String label, boolean letter) {
        if (pending != null) cancelVoice(true);
        if (editor() == null) return;
        deleted = ""; lastSpace = 0; correctionResult = "";
        if (!zh() && letter && !plainLatin) {
            if (!contextEndsWith(typedEnglish)) typedEnglish = "";
            typedEnglish += label;
        } else if (!letter) correctEnglishBoundary("");
        if (shortcutsExpanded) { shortcutsExpanded = false; refreshStrip(); }
        if (letter && zh() && !shifted && !caps) {
            if (spelling.length() >= 48) finishSpelling(true);
            spelling += label;
            compose();
        } else {
            finishSpelling(true);
            String insertion = label;
            if (!zh() && !plainLatin && prefs().getBoolean("smartSpacing", true) && ",!?;:".contains(label)) insertion += " ";
            editor().commitText(insertion, 1);
        }
        if (symbols && label.codePoints().allMatch(c -> {
            int t = Character.getType(c); return t >= Character.DASH_PUNCTUATION && t <= Character.OTHER_PUNCTUATION || t == Character.INITIAL_QUOTE_PUNCTUATION || t == Character.FINAL_QUOTE_PUNCTUATION;
        })) { symbols = more = false; render(); }
        if (shifted && !caps) {
            shifted = false;
            render();
        }
    }

    private void compose() {
        if (editor() == null) return;
        editor().setComposingText(spelling, 1);
        choices = spelling.isEmpty() ? Collections.emptyList() : dictionary.lookup(spelling);
        if (!spelling.isEmpty() && prefs().getBoolean("mixedTyping", false) && !choices.contains(spelling)) {
            choices = new ArrayList<>(choices); choices.add(spelling);
        }
        refreshStrip();
    }

    private void finishSpelling(boolean first) {
        if (spelling.isEmpty()) return;
        String text = first && !choices.isEmpty() ? choices.get(0) : spelling;
        accept(text);
    }

    private void accept(String text) {
        boolean redraw = expanded;
        expanded = false;
        spelling = "";
        choices = Collections.emptyList();
        if (editor() != null) editor().commitText(text, 1);
        if (redraw) render();
        else refreshStrip();
    }

    private void space() {
        deleted = "";
        if (!spelling.isEmpty()) {
            String first = choices.isEmpty() ? spelling : choices.get(0);
            accept(first.matches("[a-zA-Z]+") ? first + " " : first);
        } else if (editor() != null) {
            long now = SystemClock.uptimeMillis();
            String before = contextText(true), after = contextText(false);
            if (!plainLatin && !numeric && !phone && selectionStart == selectionEnd && now - lastSpace <= 450
                    && before.equals(spaceBefore) && after.equals(spaceAfter) && before.endsWith(" ")
                    && before.length() > 1 && Character.isLetterOrDigit(before.codePointBefore(before.length() - 1))) {
                editor().deleteSurroundingText(1, 0); editor().commitText(zh() ? "。" : ". ", 1); lastSpace = 0; typedEnglish = "";
            } else {
                correctEnglishBoundary(" "); editor().commitText(" ", 1);
                lastSpace = now; spaceBefore = contextText(true); spaceAfter = contextText(false);
            }
        }
    }
    private boolean contextEndsWith(String text) {
        if (editor() == null) return false;
        CharSequence before = editor().getTextBeforeCursor(Math.max(1, text.length()), 0);
        return before != null && before.toString().endsWith(text);
    }
    private void correctEnglishBoundary(String suffix) {
        if (zh() || plainLatin || secure || typedEnglish.isEmpty() || editor() == null || selectionStart != selectionEnd
                || !prefs().getBoolean("autoCorrection", true) || !contextEndsWith(typedEnglish)) { typedEnglish = ""; return; }
        String corrected = dictionary.correctEnglish(typedEnglish);
        if (!corrected.equals(typedEnglish)) {
            correctionOriginal = typedEnglish + suffix; correctionResult = corrected + suffix; correctionAfter = contextText(false);
            editor().deleteSurroundingText(typedEnglish.length(), 0); editor().commitText(corrected, 1);
        }
        typedEnglish = "";
    }

    private void erase() {
        if (pending != null) cancelVoice(true);
        lastSpace = 0; typedEnglish = ""; deleted = "";
        if (!spelling.isEmpty()) {
            spelling = spelling.substring(0, spelling.length() - 1);
            if (spelling.isEmpty()) accept("");
            else compose();
        } else if (mini) editSwipe(-dp(48), 0);
        else if (!correctionResult.isEmpty() && contextEndsWith(correctionResult) && correctionAfter.equals(contextText(false))) {
            editor().deleteSurroundingText(correctionResult.length(), 0); editor().commitText(correctionOriginal, 1);
            typedEnglish = ""; correctionResult = "";
        } else { correctionResult = ""; sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL); }
    }

    private void enter() {
        if (pending != null) cancelVoice(true);
        deleted = "";
        if (!spelling.isEmpty()) {
            finishSpelling(false);
            return;
        }
        EditorInfo info = getCurrentInputEditorInfo();
        if (editor() == null || info == null) return;
        if (info.actionLabel != null
                && (info.imeOptions & EditorInfo.IME_FLAG_NO_ENTER_ACTION) == 0)
            editor().performEditorAction(info.actionId);
        else if (!sendDefaultEditorAction(true)) sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER);
    }

    private void submitDictation() {
        EditorInfo info = getCurrentInputEditorInfo();
        if (editor() != null && info != null && (info.imeOptions & EditorInfo.IME_MASK_ACTION) == EditorInfo.IME_ACTION_SEND) {
            if (editor().performEditorAction(EditorInfo.IME_ACTION_SEND)) return;
        }
        message("Text ready. Tap Send in the app.");
    }

    private void clearAutofill() {
        autofillGeneration++;
        autofillChips.clear();
    }

    @android.annotation.TargetApi(30)
    @Override
    public InlineSuggestionsRequest onCreateInlineSuggestionsRequest(Bundle extras) {
        android.util.Size minimum = new android.util.Size(dp(40), dp(36));
        android.util.Size maximum =
                new android.util.Size(getResources().getDisplayMetrics().widthPixels, dp(40));
        Bundle style =
                androidx.autofill.inline.UiVersions.newStylesBuilder()
                        .addStyle(
                                androidx.autofill.inline.v1.InlineSuggestionUi.newStyleBuilder()
                                        .build())
                        .build();
        android.widget.inline.InlinePresentationSpec spec =
                new android.widget.inline.InlinePresentationSpec.Builder(minimum, maximum)
                        .setStyle(style)
                        .build();
        return new InlineSuggestionsRequest.Builder(Collections.singletonList(spec))
                .setMaxSuggestionCount(6)
                .build();
    }

    @android.annotation.TargetApi(30)
    @Override
    public boolean onInlineSuggestionsResponse(InlineSuggestionsResponse response) {
        clearAutofill();
        int generation = autofillGeneration;
        refreshStrip();
        for (InlineSuggestion suggestion : response.getInlineSuggestions()) {
            suggestion.inflate(
                    this,
                    new android.util.Size(-2, dp(36)),
                    getMainExecutor(),
                    chip -> {
                        if (chip != null && generation == autofillGeneration) {
                            autofillChips.add(chip);
                            refreshStrip();
                        }
                    });
        }
        return true;
    }

    private static final String MICROPHONE_PERMISSION_NOTICE = "Microphone permission needed";

    private void refreshStrip() {
        if (strip == null) return;
        strip.removeAllViews();
        if (voice != null && (notice.isEmpty() || notice.equals("Finishing…") || notice.equals("Polishing…"))) return;
        if (voice != null || !notice.isEmpty()) {
            TextView status =
                    tile(!notice.isEmpty() ? notice : "Listening…", "Dictation status", 15);
            status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
            strip.addView(status, new LinearLayout.LayoutParams(0, -1, 1));
            if (MICROPHONE_PERMISSION_NOTICE.equals(notice)) {
                TextView settings = tile("Settings", "Open microphone permission settings", 15);
                settings.setPadding(dp(12), 0, dp(12), 0);
                settings.setOnClickListener(v -> startActivity(new Intent(
                        android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        android.net.Uri.fromParts("package", getPackageName(), null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)));
                strip.addView(settings, -2, -1);
            }
            if (voice != null && pending == null && !notice.equals("Finishing…"))
                tool("✓", "Finish dictation", () -> stopVoice(false));
            if (voice != null) tool("×", "Cancel dictation", () -> cancelVoice(false));
            return;
        }
        if (mini && !emoji && !symbols && !numericPage && !numeric && !phone) return;
        addPills();
        if (shortcutsExpanded) return;
        if (!spelling.isEmpty()) {
            HorizontalScrollView scroller = new HorizontalScrollView(this);
            scroller.setHorizontalScrollBarEnabled(false);
            LinearLayout options = new LinearLayout(this);
            for (String word : choices) options.addView(option(word));
            scroller.addView(options);
            scroller.setOnTouchListener(new View.OnTouchListener() {
                float x,y; boolean consumed;
                public boolean onTouch(View v, MotionEvent e) {
                    if (e.getActionMasked() == MotionEvent.ACTION_DOWN) { x=e.getX(); y=e.getY(); consumed=false; }
                    if (e.getActionMasked() == MotionEvent.ACTION_MOVE && !consumed && e.getY()-y > dp(28) && e.getY()-y > Math.abs(e.getX()-x)*1.25f) { consumed=true; setCandidatesExpanded(true); return true; }
                    return consumed;
                }
            });
            strip.addView(scroller, new LinearLayout.LayoutParams(0, -1, 1));
            tool(
                    expanded ? "⌃" : "⌄",
                    "Expand or collapse candidates",
                    () -> {
                        setCandidatesExpanded(!expanded);
                    });
            return;
        }
        if (!autofillChips.isEmpty()) {
            HorizontalScrollView scroller = new HorizontalScrollView(this);
            LinearLayout chips = new LinearLayout(this);
            for (View chip : autofillChips) {
                if (chip.getParent() instanceof ViewGroup)
                    ((ViewGroup) chip.getParent()).removeView(chip);
                chips.addView(chip);
            }
            scroller.addView(chips);
            strip.addView(scroller, new LinearLayout.LayoutParams(0, -1, 1));
            return;
        }
        if (!englishWord.isEmpty()
                && !zh()
                && !symbols
                && !emoji
                && !mini
                && !numericPage
                && !plainLatin) {
            List<String> options = new ArrayList<>();
            options.add(englishWord);
            options.addAll(dictionary.completions(englishWord));
            String prefix = englishWord;
            HorizontalScrollView scroller = new HorizontalScrollView(this);
            LinearLayout items = new LinearLayout(this); scroller.setHorizontalScrollBarEnabled(false); scroller.addView(items);
            for (int i = 0; i < Math.min(3, options.size()); i++) {
                String option = options.get(i);
                if (i > 0 && Character.isUpperCase(prefix.charAt(0))) option = Character.toUpperCase(option.charAt(0)) + option.substring(1);
                String word = option;
                TextView candidate = tile(word, word, 18); candidate.setPadding(dp(10),0,dp(10),0);
                if (i == 0) { candidate.setTypeface(Typeface.DEFAULT,Typeface.BOLD); pillBackground(candidate); }
                candidate.setOnClickListener(v -> { if (englishPrefix().equals(prefix)) { editor().commitText(word.substring(prefix.length()) + (prefs().getBoolean("smartSpacing",true) ? " " : ""), 1); typedEnglish = ""; } });
                items.addView(candidate, -2, -1);
            }
            strip.addView(scroller, new LinearLayout.LayoutParams(0,-1,1));
            return;
        }
    }

    private void addPills() {
        ImageButton shortcut = icon(R.drawable.tools_grid, "Shortcuts", () -> { shortcutsExpanded = !shortcutsExpanded; refreshStrip(); });
        pillBackground(shortcut);
        View gesture = tile("↔", "Editing gestures: left delete word, right restore, down new line, up end of text", 20);
        pillBackground(gesture);
        gesture.setOnClickListener(v -> {
            PopupMenu menu = new PopupMenu(this, gesture);
            String[] titles = {"Delete word", "Restore word", "New line", "End of text"};
            for (int i=0;i<titles.length;i++) menu.getMenu().add(0,i,i,titles[i]);
            menu.setOnMenuItemClickListener(item -> { int i=item.getItemId(); editSwipe(i==0 ? -48 : i==1 ? 48 : 0, i==2 ? 48 : i==3 ? -48 : 0); return true; }); menu.show();
        });
        final InputConnection owner = editor();
        gesture.setOnTouchListener(new View.OnTouchListener() {
            float x, y; String before, after; int start, end;
            public boolean onTouch(View v, MotionEvent e) {
                if (e.getActionMasked() == MotionEvent.ACTION_DOWN) {
                    x = e.getX(); y = e.getY(); start = selectionStart; end = selectionEnd;
                    before = contextText(true); after = contextText(false); v.setAlpha(.55f); return true;
                }
                if (e.getActionMasked() == MotionEvent.ACTION_UP) {
                    v.setAlpha(1); float dx = e.getX() - x, dy = e.getY() - y;
                    if (editor() == owner && start == selectionStart && end == selectionEnd && before.equals(contextText(true)) && after.equals(contextText(false))
                        && Math.max(Math.abs(dx), Math.abs(dy)) >= dp(28) && Math.max(Math.abs(dx), Math.abs(dy)) > Math.min(Math.abs(dx), Math.abs(dy)) * 1.25f) {
                        editSwipe(dx, dy); KeyFeedback.play(v, HapticFeedbackConstants.KEYBOARD_TAP);
                    } else if (Math.hypot(dx,dy) < dp(8)) v.performClick();
                    return true;
                }
                if (e.getActionMasked() == MotionEvent.ACTION_CANCEL) v.setAlpha(1);
                return true;
            }
        });
        if (shortcutsExpanded) {
            if (!secure) {
                icon(R.drawable.clipboard, "Paste", this::pasteCurrentClipboard);
                ImageButton history = icon(R.drawable.history, "Clipboard History", () -> {});
                history.setOnClickListener(v -> showClipboardHistory(v));
                if (!copiedCode.isEmpty() && SystemClock.uptimeMillis() - copiedCodeAt < 120000)
                    icon(R.drawable.code, "Paste Code", this::pasteCode);
            }
            icon(R.drawable.onepassword, "Open 1Password", () -> openShortcut("password"));
            icon(R.drawable.messages, "Open Messages", () -> openShortcut("messages"));
            icon(R.drawable.phone, "Open Phone", () -> openShortcut("phone"));
            LinearLayout actions = new LinearLayout(this);
            while (strip.getChildCount() > 1) {
                View button = strip.getChildAt(1); strip.removeViewAt(1); actions.addView(button, dp(44), dp(44));
            }
            HorizontalScrollView scroller = new HorizontalScrollView(this); scroller.setHorizontalScrollBarEnabled(false); scroller.addView(actions);
            strip.addView(scroller, new LinearLayout.LayoutParams(0, dp(44), 1));
        }
        // Attach last after this refresh has populated its candidate contents.
        LinearLayout destination = strip;
        destination.post(() -> {
            if (strip != destination || shortcut.getParent() != destination) return;
            if (!shortcutsExpanded && destination.getChildCount() == 1) toolbarSpace();
            destination.addView(gesture, dp(64), dp(44));
        });
    }
    private void pasteCurrentClipboard() {
        InputConnection owner = editor();
        if (owner == null || secure || voice != null || pending != null || !spelling.isEmpty()) return;
        String copied = ClipboardHistory.textFrom(getSystemService(ClipboardManager.class).getPrimaryClip());
        if (owner == editor() && owner.performContextMenuAction(android.R.id.paste)) {
            clipboardHistory.record(copied);
            typedEnglish = correctionOriginal = correctionResult = deleted = "";
        }
    }
    private void showClipboardHistory(View anchor) {
        InputConnection owner = editor();
        String before = contextText(true), after = contextText(false);
        CharSequence selected = owner == null ? null : owner.getSelectedText(0);
        String selection = selected == null ? "" : selected.toString();
        int start = selectionStart, end = selectionEnd;
        List<String> clips = clipboardHistory.items();
        PopupMenu menu = new PopupMenu(this, anchor);
        boolean canPaste = owner != null && !secure && voice == null && pending == null && spelling.isEmpty();
        for (int i = 0; i < clips.size(); i++) menu.getMenu().add(0, i, i, ClipboardHistory.preview(clips.get(i))).setEnabled(canPaste);
        if (clips.isEmpty()) menu.getMenu().add("No recent text clips").setEnabled(false);
        else menu.getMenu().add(0, 5, 5, "Clear History");
        menu.setOnMenuItemClickListener(item -> {
            int index = item.getItemId();
            if (index == 5) { clipboardHistory.clear(); return true; }
            CharSequence currentSelected = owner == null ? null : owner.getSelectedText(0);
            String currentSelection = currentSelected == null ? "" : currentSelected.toString();
            if (index < clips.size() && owner != null && owner == editor() && isInputViewShown() && !secure
                && voice == null && pending == null && spelling.isEmpty() && start == selectionStart && end == selectionEnd
                && before.equals(contextText(true)) && after.equals(contextText(false)) && selection.equals(currentSelection)) {
                owner.commitText(clips.get(index), 1);
                typedEnglish = correctionOriginal = correctionResult = deleted = "";
            }
            return true;
        });
        menu.show();
    }
    private void pillBackground(View view) {
        GradientDrawable shape = new GradientDrawable(); shape.setColor(special); shape.setCornerRadius(dp(18));
        view.setBackground(new InsetDrawable(shape, dp(3), dp(6), dp(3), dp(6)));
    }
    private void openShortcut(String app) {
        try {
            Intent intent;
            if (app.equals("password")) {
                intent = getPackageManager().getLaunchIntentForPackage("com.onepassword.android");
                if (intent == null) intent = getPackageManager().getLaunchIntentForPackage("com.agilebits.onepassword");
                if (intent == null) { message("Install 1Password to use this shortcut"); return; }
            } else if (app.equals("messages")) intent = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_MESSAGING);
            else intent = new Intent(Intent.ACTION_DIAL);
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (ActivityNotFoundException error) { message("This app is unavailable"); }
    }

    private void setCandidatesExpanded(boolean value) {
        if (expanded == value) return;
        expanded = value;
        if (android.animation.ValueAnimator.areAnimatorsEnabled()) {
            android.transition.AutoTransition transition = new android.transition.AutoTransition(); transition.setDuration(220);
            android.transition.TransitionManager.beginDelayedTransition(board, transition);
        }
        render();
    }
    private void toolbarSpace() {
        strip.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1));
    }

    private void pasteCode() {
        ClipboardManager manager = getSystemService(ClipboardManager.class);
        ClipData clip = manager.getPrimaryClip();
        if (clip == null || clip.getItemCount() != 1 || editor() == null) return;
        CharSequence text = clip.getItemAt(0).getText();
        String code = CopiedCode.extract(text);
        if (code != null && code.equals(copiedCode) && SystemClock.uptimeMillis() - copiedCodeAt < 120000) { editor().commitText(code, 1); copiedCode = ""; refreshStrip(); }
        else message("No unique verification code");
    }

    private ImageButton icon(int resource, String label, Runnable click) {
        ImageButton button = new ImageButton(this);
        button.setImageResource(resource);
        button.setImageTintList(ColorStateList.valueOf(ink));
        button.setScaleType(ImageView.ScaleType.FIT_CENTER);
        button.setPadding(dp(12), dp(12), dp(12), dp(12));
        button.setBackgroundColor(0);
        button.setContentDescription(label);
        button.setOnClickListener(v -> click.run());
        if (resource == R.drawable.mic) {
            GradientDrawable circle = new GradientDrawable();
            circle.setShape(GradientDrawable.OVAL);
            circle.setColor(keyColor);
            int inset = dp(5);
            button.setBackground(new InsetDrawable(circle, inset));
        }
        strip.addView(button, dp(44), dp(44));
        return button;
    }

    private void tool(String text, String label, Runnable click) {
        TextView view = tile(text, label, 22);
        view.setOnClickListener(v -> click.run());
        strip.addView(view, dp(46), -1);
    }

    private TextView option(String word) {
        TextView v = tile(word, word, 20);
        v.setPadding(dp(14), dp(5), dp(14), dp(5));
        if (!choices.isEmpty() && word.equals(choices.get(0)))
            v.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        v.setOnClickListener(it -> accept(word));
        return v;
    }

    private void candidatePanel() {
        expandedPanel = new ScrollView(this);
        LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        LinearLayout line = null;
        int width = 0, available = getResources().getDisplayMetrics().widthPixels - dp(8);
        for (String word : choices) {
            TextView v = option(word);
            int needed = (int) v.getPaint().measureText(word) + dp(30);
            if (line == null || width + needed > available) {
                line = new LinearLayout(this);
                list.addView(line);
                width = 0;
            }
            line.addView(v);
            width += needed;
        }
        expandedPanel.addView(list);
        board.addView(expandedPanel, -1, dp(200));
    }

    private void settings() {
        startActivity(
                new Intent(this, SetupActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }

    private void message(String text) {
        notice = text;
        refreshStrip();
        main.removeCallbacks(clearNotice);
        main.postDelayed(clearNotice, 3500);
    }

    private void toggleVoice() {
        if (voice == null) beginVoice();
        else stopVoice(false);
    }

    private void beginVoice() {
        if (secure || editor() == null || voice != null) return;
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            message(MICROPHONE_PERMISSION_NOTICE);
            return;
        }
        finishSpelling(true);
        deleted = "";
        notice = "";
        preview = "";
        sendAfter = translateAfter = false;
        typedEnglish = correctionResult = "";
        CharSequence selected = editor().getSelectedText(0);
        displaced = selected == null ? "" : selected.toString();
        InputConnection owner = editor();
        int start = Math.min(selectionStart, selectionEnd);
        boolean sentencePunctuation = prefs().getBoolean("sentencePunctuation", true);
        long id = ++voiceId;
        try {
            voice =
                    Dictation.start(
                            this,
                            ProviderKey.SEED.read(this),
                            zh() ? "zh-CN" : "en-US",
                            new Dictation.Listener() {
                                public void text(String result, boolean done) {
                                    if (id != voiceId || pending != null || editor() != owner) return;
                                    if (!result.isEmpty()) preview = result;
                                    if (done) {
                                        finalizeRecognition(owner, start, sentencePunctuation);
                                    } else if (!preview.isEmpty())
                                        editor().setComposingText(preview, 1);
                                }

                                public void level(float level) {
                                    main.post(() -> { if (id == voiceId && voice != null && pending == null && notice.isEmpty()) updateVoiceLevel(level); });
                                }
                                public void error(String reason) {
                                    if (id == voiceId && pending == null) {
                                        cancelVoice(true);
                                        message(reason);
                                    }
                                }
                            });
            updateVoiceLevel(0); refreshStrip();
            main.postDelayed(timeout, 90000);
        } catch (Exception e) {
            closeVoice();
            message("Check the speech service and microphone in Settings");
        }
    }

    private void finalizeRecognition(InputConnection owner, int start, boolean sentencePunctuation) {
        main.removeCallbacks(timeout);
        main.removeCallbacks(clearNotice);
        if (preview.isEmpty()) {
            closeVoice();
            return;
        }
        String key = "";
        if (translateAfter || prefs().getBoolean("polish", true)) {
            try { key = ProviderKey.ARK.read(this); } catch (Exception ignored) { }
        }
        if (key.isEmpty() || start < 0 || owner.getExtractedText(new ExtractedTextRequest(), 0) == null) {
            boolean send = owner.commitText(SentencePunctuation.apply(preview, sentencePunctuation), 1) && sendAfter;
            closeVoice();
            if (prefs().getBoolean("polish", true)) message(key.isEmpty()
                    ? "Polishing is unavailable in this build."
                    : "Polishing unavailable in this editor.");
            if (send) submitDictation();
            return;
        }
        if (!owner.setComposingText(preview, 1)) {
            owner.commitText(SentencePunctuation.apply(preview, sentencePunctuation), 1);
            closeVoice();
            message("Polishing unavailable in this editor.");
            return;
        }
        PendingDictation draft = new PendingDictation(owner, start, preview);
        if (!draft.owns(owner)) {
            // Editors that cannot verify the range keep the ASR draft locally.
            owner.finishComposingText();
            closeVoice();
            message("Polishing unavailable in this editor.");
            return;
        }
        pending = draft;
        notice = "Polishing…";
        refreshStrip();
        try {
            polishCall = DictationPolisher.start(preview, key, translateAfter,
                    text -> main.post(() -> finishPolish(draft, text, sentencePunctuation)));
        } catch (Exception e) {
            finishPolish(draft, null, sentencePunctuation);
        }
    }

    private void finishPolish(PendingDictation draft, String text, boolean sentencePunctuation) {
        if (pending != draft) return;
        boolean send = draft.complete(editor(), SentencePunctuation.apply(text == null ? preview : text, sentencePunctuation)) && sendAfter;
        closeVoice();
        if (text == null) message("Polishing unavailable. Kept the transcript.");
        if (send) submitDictation();
    }

    private void updateVoiceLevel(float raw) {
        long now = SystemClock.uptimeMillis();
        boolean listening = voice != null && pending == null && notice.isEmpty();
        float target = listening ? (float) Math.sqrt(Math.max(0, Math.min(1, (raw - .06f) / .94f))) : 0;
        float dt = Math.max(0, now - lastMeter); lastMeter = now;
        voiceLevel += (target - voiceLevel) * (1f - (float) Math.exp(-dt / (target > voiceLevel ? 35 : 140)));
        if (!listening) voiceLevel = 0;
        if (board != null) illuminate(board, listening);
    }
    private void illuminate(View view, boolean listening) {
        if (view instanceof Keycap) {
            Keycap cap = (Keycap) view;
            int[] a = new int[2], b = new int[2]; cap.getLocationOnScreen(a); board.getLocationOnScreen(b);
            float position = (a[0] - b[0] + cap.getWidth() / 2f) / Math.max(1, board.getWidth());
            float extent = Math.max(0, 1 - Math.abs(position - .5f) * 2 / Math.max(.12f, voiceLevel));
            cap.setVoice(listening, extent * voiceLevel);
        } else if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) illuminate(group.getChildAt(i), listening);
        }
    }

    private void stopVoice(boolean send) {
        if (voice == null || pending != null) return;
        sendAfter = send;
        voice.stop();
        notice = "Finishing…"; updateVoiceLevel(0);
        refreshStrip();
        main.removeCallbacks(timeout);
        main.postDelayed(timeout, 12000);
    }

    private void closeVoice() {
        ++voiceId;
        pending = null;
        if (polishCall != null) polishCall.cancel();
        polishCall = null;
        main.removeCallbacks(timeout);
        if (voice != null) voice.cancel();
        voice = null;
        preview = "";
        displaced = "";
        notice = "";
        sendAfter = translateAfter = false; if (languageKey != null) languageKey.setAlpha(1); updateVoiceLevel(0);
        refreshStrip();
    }

    private void cancelVoice(boolean keep) {
        if (voice == null && pending == null && polishCall == null) return;
        if (pending != null) pending.cancel(editor());
        else if (!preview.isEmpty() && editor() != null) {
            if (keep) editor().finishComposingText();
            else editor().commitText(displaced, 1);
        }
        closeVoice();
    }

    private void editSwipe(float dx, float dy) {
        if (pending != null) cancelVoice(true);
        if (editor() == null) return;
        finishSpelling(true);
        if (-dy > Math.abs(dx)) {
            ExtractedText text = editor().getExtractedText(new ExtractedTextRequest(), 0);
            if (text != null && text.text != null && text.partialStartOffset < 0 && text.startOffset == 0)
                editor().setSelection(text.text.length(), text.text.length());
            else {
                long now = SystemClock.uptimeMillis();
                editor().sendKeyEvent(new KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MOVE_END, 0, KeyEvent.META_CTRL_ON));
                editor().sendKeyEvent(new KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MOVE_END, 0, KeyEvent.META_CTRL_ON));
            }
            deleted = "";
        } else if (dy > Math.abs(dx)) {
            editor().commitText("\u2028", 1);
            deleted = "";
        } else if (dx > 0) {
            if (!deleted.isEmpty()
                    && selectionStart == restorePosition
                    && selectionEnd == selectionStart
                    && restoreBefore.contentEquals(contextText(true))
                    && restoreAfter.contentEquals(contextText(false)))
                editor().commitText(deleted, 1);
            deleted = "";
        } else if (!secure && selectionStart == selectionEnd) {
            CharSequence before = editor().getTextBeforeCursor(256, 0);
            if (before == null) return;
            String text = before.toString();
            int i = text.length();
            while (i > 0 && Character.isWhitespace(text.codePointBefore(i)) && text.charAt(i - 1) != '\n')
                i -= Character.charCount(text.codePointBefore(i));
            if (i > 0) {
                android.icu.text.BreakIterator words = android.icu.text.BreakIterator.getWordInstance(zh() ? Locale.CHINESE : Locale.ENGLISH);
                words.setText(text.substring(0, i));
                int boundary = words.preceding(i);
                i = Math.max(0, boundary);
            }
            deleted = text.substring(i);
            restorePosition = selectionStart - deleted.length();
            restoreBefore = text.substring(Math.max(0, i - 16), i);
            restoreAfter = contextText(false);
            editor().deleteSurroundingText(deleted.length(), 0);
        }
    }

    private String contextText(boolean before) {
        CharSequence value =
                before ? editor().getTextBeforeCursor(16, 0) : editor().getTextAfterCursor(16, 0);
        return value == null ? "" : value.toString();
    }

    private boolean inside(View v, float x, float y) {
        if (v == null) return false;
        int[] loc = new int[2];
        v.getLocationOnScreen(loc);
        return x >= loc[0]
                && x < loc[0] + v.getWidth()
                && y >= loc[1]
                && y < loc[1] + v.getHeight();
    }

    private final class KeyGesture implements View.OnTouchListener {
        final TextView key;
        final String kind;
        float x, y;
        boolean consumed, dictating, cursor, gap;
        long heldId;
        PopupWindow bubble;
        LinearLayout alternatives;
        List<String> symbolsToChoose;
        int symbolIndex;
        String symbolBefore, symbolAfter;
        InputConnection symbolOwner;
        void hideBubble() { if (bubble != null) bubble.dismiss(); bubble = null; alternatives = null; symbolsToChoose = null; }
        void preview() {
            if (!kind.equals("letter") && !kind.equals("symbol")) return;
            TextView label = tile(key.getText().toString(), key.getContentDescription().toString(), 30);
            label.setBackgroundColor(keyColor); bubble = new PopupWindow(label, Math.max(dp(48), key.getWidth()+dp(12)), dp(54), false);
            bubble.setTouchable(false); bubble.setElevation(dp(3)); int[] location = new int[2]; key.getLocationOnScreen(location);
            bubble.showAtLocation(board, Gravity.TOP|Gravity.LEFT, location[0]-dp(6), Math.max(0,location[1]-dp(50)));
        }
        void showSymbols() {
            hideBubble(); symbolsToChoose = MobileSymbols.alternatives(key.getText().toString());
            symbolBefore = contextText(true); symbolAfter = contextText(false); symbolOwner = editor(); symbolIndex = 0;
            alternatives = new LinearLayout(KeyboardService.this); alternatives.setBackgroundColor(keyColor);
            for (String value : symbolsToChoose) alternatives.addView(tile(value,value,25),new LinearLayout.LayoutParams(0,-1,1));
            int width = Math.min(board.getWidth(), dp(44)*symbolsToChoose.size());
            bubble = new PopupWindow(alternatives,width,dp(54),false); bubble.setTouchable(false); bubble.setElevation(dp(4));
            int[] loc = new int[2], parent = new int[2]; key.getLocationOnScreen(loc); board.getLocationOnScreen(parent);
            bubble.showAtLocation(board, Gravity.TOP|Gravity.LEFT, Math.max(parent[0],Math.min(loc[0],parent[0]+board.getWidth()-width)),Math.max(0,loc[1]-dp(52)));
        }

        KeyGesture(TextView key, String kind) {
            this.key = key;
            this.kind = kind;
            key.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener() {
                public void onViewAttachedToWindow(View v) {}
                public void onViewDetachedFromWindow(View v) { hideBubble(); key.removeCallbacks(holdAction); key.removeCallbacks(repeat); }
            });
        }

        final Runnable repeat =
                new Runnable() {
                    public void run() {
                        if (key.isPressed() && key.isShown() && key.isAttachedToWindow()) {
                            erase();
                            key.postDelayed(this, 80);
                        }
                    }
                };

        void hold() {
            if (!key.isPressed() || !key.isShown() || !key.isAttachedToWindow()) return;
            hideBubble();
            if (!gap && kind.equals("Space")) {
                finishSpelling(true);
                cursor = true;
            } else if (!gap && kind.equals("Delete")) {
                repeat.run();
            } else if (gap || kind.equals("letter") || kind.equals("Hold to dictate")) {
                if (secure) return;
                beginVoice();
                heldId = voiceId;
                dictating = voice != null;
            } else if (kind.equals("symbol")) {
                showSymbols();
            } else return;
            consumed = true;
            KeyFeedback.play(key, HapticFeedbackConstants.LONG_PRESS);
        }

        final Runnable holdAction = this::hold;

        public boolean onTouch(View v, MotionEvent event) {
            float px = event.getRawX(), py = event.getRawY();
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    if (voice != null || pending != null) cancelVoice(true);
                    gap = !inside(key, px, py);
                    x = px;
                    y = py;
                    consumed = dictating = cursor = false;
                    key.setPressed(true);
                    KeyFeedback.play(key, HapticFeedbackConstants.KEYBOARD_TAP);
                    preview(); key.postDelayed(holdAction, kind.equals("Hold to dictate") ? 250 : 380);
                    return true;
                case MotionEvent.ACTION_MOVE:
                    if (symbolsToChoose != null && alternatives != null) {
                        int[] loc = new int[2]; alternatives.getLocationOnScreen(loc);
                        symbolIndex = Math.max(0, Math.min(symbolsToChoose.size()-1, (int)((px-loc[0])/Math.max(1,alternatives.getWidth()/symbolsToChoose.size()))));
                        for (int i=0;i<alternatives.getChildCount();i++) alternatives.getChildAt(i).setAlpha(i==symbolIndex ? 1 : .45f);
                        return true;
                    }
                    if (dictating && heldId == voiceId) {
                        if (inside(deleteKey, px, py) || !inside(board, px, py)) {
                            cancelVoice(false);
                            dictating = false;
                        } else if (inside(returnKey, px, py)) {
                            translateAfter = false; stopVoice(true);
                            dictating = false;
                        } else {
                            boolean hovering = inside(languageKey, px, py);
                            if (hovering != translateAfter && hovering) KeyFeedback.play(key, HapticFeedbackConstants.LONG_PRESS);
                            translateAfter = hovering;
                            if (languageKey != null) languageKey.setAlpha(hovering ? .45f : 1);
                        }
                    } else if (!gap && consumed && kind.equals("Delete") && px - x < -dp(65)) {
                        key.removeCallbacks(repeat);
                        if (editor() != null
                                && editor().performContextMenuAction(android.R.id.selectAll))
                            editor().commitText("", 1);
                        x = Float.NEGATIVE_INFINITY;
                    } else if (cursor) {
                        int horizontal = (int) ((px - x) / dp(13)),
                                vertical = (int) ((py - y) / dp(25));
                        if (vertical != 0) {
                            sendDownUpKeyEvents(
                                    vertical > 0
                                            ? KeyEvent.KEYCODE_DPAD_DOWN
                                            : KeyEvent.KEYCODE_DPAD_UP);
                            y = py;
                        }
                        for (int i = 0; i < Math.min(20, Math.abs(horizontal)); i++)
                            sendDownUpKeyEvents(
                                    horizontal > 0
                                            ? KeyEvent.KEYCODE_DPAD_RIGHT
                                            : KeyEvent.KEYCODE_DPAD_LEFT);
                        x += horizontal * dp(13);
                    } else if (!consumed && !gap && kind.equals("letter") && y - py > dp(35)) {
                        int i =
                                "qwertyuiop"
                                        .indexOf(key.getText().toString().toLowerCase(Locale.ROOT));
                        if (i >= 0) {
                            key.removeCallbacks(holdAction);
                            type(String.valueOf((i + 1) % 10), false);
                            consumed = true;
                        }
                    } else if (!consumed && Math.hypot(px - x, py - y) > dp(14)) {
                        key.removeCallbacks(holdAction); hideBubble();
                    }
                    return true;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    key.removeCallbacks(holdAction);
                    key.removeCallbacks(repeat);
                    key.setPressed(false);
                    String choice = symbolsToChoose != null && event.getActionMasked() == MotionEvent.ACTION_UP ? symbolsToChoose.get(symbolIndex) : null;
                    hideBubble();
                    if (choice != null && editor() == symbolOwner && symbolBefore.equals(contextText(true)) && symbolAfter.equals(contextText(false))) type(choice,false);
                    if (event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
                        if (dictating && heldId == voiceId) cancelVoice(false);
                    } else if (dictating && heldId == voiceId) stopVoice(false);
                    else if (!consumed && !kind.equals("Hold to dictate")) key.performClick();
                    return true;
                default:
                    return true;
            }
        }
    }
}

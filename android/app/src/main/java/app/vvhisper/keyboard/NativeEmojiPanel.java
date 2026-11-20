package app.vvhisper.keyboard;

import android.content.Context;
import android.view.*;
import android.widget.*;
import java.util.*;
import java.util.function.Consumer;
import org.json.*;

/** Offline Unicode catalog; no history, network or automatic learning. */
final class NativeEmojiPanel extends LinearLayout {
    private final List<JSONObject> all = new ArrayList<>(), base = new ArrayList<>();
    private final Map<String, List<JSONObject>> variants = new HashMap<>();
    private final List<String> categories = new ArrayList<>();
    private final GridView grid;
    private final int ink;
    private int tone;
    private String category;
    NativeEmojiPanel(Context context, int ink, Runnable press, Consumer<String> insert, Runnable close, Runnable delete) {
        super(context); this.ink = ink; setOrientation(VERTICAL);
        try (java.io.InputStream in = context.getAssets().open("EmojiCatalog.json")) {
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
            byte[] block = new byte[8192]; for (int count; (count = in.read(block)) != -1;) bytes.write(block, 0, count);
            JSONArray data = new JSONArray(bytes.toString("UTF-8"));
            for (int i = 0; i < data.length(); i++) {
                JSONObject item = data.getJSONObject(i); all.add(item);
                variants.computeIfAbsent(identity(item.getString("glyph")), key -> new ArrayList<>()).add(item);
                if (item.getString("glyph").codePoints().noneMatch(c -> c >= 0x1F3FB && c <= 0x1F3FF)) {
                    base.add(item); String group = item.getString("category"); if (!categories.contains(group)) categories.add(group);
                }
            }
        } catch (Exception ignored) { }
        HorizontalScrollView scroll = new HorizontalScrollView(context); LinearLayout groups = new LinearLayout(context); scroll.addView(groups); addView(scroll, -1, dp(44));
        String[] icons = {"☺", "☝", "🐻", "🍎", "🚗", "⚽", "💡", "♥", "🏳"};
        for (int i = 0; i < categories.size(); i++) {
            String name = categories.get(i); TextView button = tile(icons[i], name);
            groups.addView(button, dp(44), -1); button.setOnClickListener(v -> show(name));
        }
        grid = new GridView(context); grid.setNumColumns(GridView.AUTO_FIT); grid.setColumnWidth(dp(48)); grid.setStretchMode(GridView.STRETCH_COLUMN_WIDTH);
        addView(grid, new LayoutParams(-1, 0, 1));
        grid.setOnTouchListener((v,e) -> { if (e.getActionMasked() == MotionEvent.ACTION_DOWN) press.run(); return false; });
        grid.setOnItemClickListener((p,v,pos,id) -> { JSONObject item = (JSONObject) p.getItemAtPosition(pos); insert.accept(item.optString("glyph")); });
        LinearLayout bottom = new LinearLayout(context); addView(bottom, -1, dp(44));
        TextView abc = tile("ABC", "Letters"), tones = tile("☝", "Skin tone"), backspace = tile("⌫", "Delete");
        bottom.addView(abc, new LayoutParams(0, -1, 1)); bottom.addView(tones, new LayoutParams(0, -1, 1)); bottom.addView(backspace, new LayoutParams(0, -1, 1));
        abc.setOnClickListener(v -> close.run()); backspace.setOnClickListener(v -> delete.run());
        tones.setOnClickListener(v -> { PopupMenu menu = new PopupMenu(context, tones);
            for (int i = 0; i <= 5; i++) menu.getMenu().add(0,i,i,i == 0 ? "Default" : new String(Character.toChars(0x1F3FA+i)));
            menu.setOnMenuItemClickListener(item -> { tone = item.getItemId(); show(category); return true; }); menu.show(); });
        if (!categories.isEmpty()) show(categories.get(0));
    }
    private int dp(float value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private TextView tile(String text, String label) { TextView v = new TextView(getContext()); v.setGravity(Gravity.CENTER); v.setText(text); v.setTextColor(ink); v.setTextSize(24); v.setContentDescription(label); return v; }
    private static String identity(String text) { StringBuilder out = new StringBuilder(); text.codePoints().filter(c -> c != 0xFE0F && !(c >= 0x1F3FB && c <= 0x1F3FF)).forEach(out::appendCodePoint); return out.toString(); }
    private void show(String group) {
        category = group; List<JSONObject> items = new ArrayList<>();
        for (JSONObject item : base) if (item.optString("category").equals(group)) {
            JSONObject result = item;
            if (tone > 0) for (JSONObject candidate : variants.get(identity(item.optString("glyph")))) {
                String glyph = candidate.optString("glyph");
                if (identity(glyph).equals(identity(item.optString("glyph"))) && glyph.codePoints().anyMatch(c -> c == 0x1F3FA+tone)
                    && glyph.codePoints().filter(c -> c >= 0x1F3FB && c <= 0x1F3FF).allMatch(c -> c == 0x1F3FA+tone)) { result = candidate; break; }
            }
            items.add(result);
        }
        grid.setAdapter(new BaseAdapter() {
            public int getCount() { return items.size(); }
            public Object getItem(int i) { return items.get(i); }
            public long getItemId(int i) { return i; }
            public View getView(int i, View recycled, ViewGroup parent) {
                JSONObject item = items.get(i); TextView v = tile(item.optString("glyph"), item.optString("name"));
                v.setLayoutParams(new AbsListView.LayoutParams(-1, dp(48))); return v;
            }
        });
    }
}

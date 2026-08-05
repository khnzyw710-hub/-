# תיקון "Context limit reached" ב-Claude Code

מסמך זה מסביר למה הופיעה ההודעה `Context limit reached · /compact or /clear to continue`
ומה בדיוק תוקן. הקובץ הזה **לא** נטען אוטומטית לזיכרון של Claude — הוא רק לתיעוד.

## מה נמדד בפועל

לא ניחוש — מדידה מתוך יומן הסשן (`~/.claude/projects/*/*.jsonl`):

| רכיב | טוקנים בתחילת סשן |
|---|---|
| סך הכל בפתיחת סשן, לפני מילה ראשונה | **41,707** |
| כל ה-skills ביחד (תיאורים בלבד) | ~2,100 |
| hooks (`SessionStart`, `UserPromptSubmit`) | 0 |
| קבצי `CLAUDE.md` בפרויקט | 0 (לא קיימים) |

**מסקנה: ה-skills לא היו הבעיה** — הם 5% מהבסיס. גם ה-hooks לא. מחיקת skills לא היתה עוזרת.

## הסיבה האמיתית

שתי סיבות נפרדות שפעלו יחד:

**1. דחיסה אוטומטית לא נכנסת בזמן.**
Claude Code דוחס את ההיסטוריה אוטומטית כשההקשר מתמלא. אבל אם פלט בודד גדול מדי
(תוצאה ענקית מכלי MCP, קובץ גדול), ההקשר מתמלא מחדש מיד אחרי כל דחיסה — הדחיסה
"נתקעת בלולאה" ואז מוצגת ההודעה הידנית `/compact or /clear`.

**2. אין תקרה לפלט של כלי MCP.**
ברירת המחדל של `MAX_MCP_OUTPUT_TOKENS` היא 25,000 טוקנים — לכל קריאה בודדת.
שתי-שלוש קריאות כאלה ממלאות את ההקשר לבד.

בנוסף, בסשנים מרוחקים (claude.ai/code) הדגל `tengu_reactive_compact_remote` מוגדר
`false`, כלומר הדחיסה ה"תגובתית" (זו שנכנסת ברגע שנתקעים) מושבתת — ולכן מקבלים את
ההודעה במקום דחיסה שקטה.

## מה תוקן

נוצר `.claude/settings.json`:

```json
{
  "autoCompactWindow": 120000,
  "env": {
    "MAX_MCP_OUTPUT_TOKENS": "10000"
  }
}
```

| הגדרה | מה היא עושה |
|---|---|
| `autoCompactWindow: 120000` | דוחס את ההיסטוריה כבר ב-120K טוקנים במקום להמתין כמעט למקסימום. הדחיסה קורית מוקדם, כשעוד יש מקום — כך לא נתקעים בקיר. |
| `MAX_MCP_OUTPUT_TOKENS: 10000` | חוסם תוצאה בודדת מכלי MCP מלתפוס יותר מ-10K טוקנים. זה מה שמונע את "לולאת הדחיסה". |

## איך להחיל את זה גם על המחשב המקומי

הקובץ בריפו חל רק כשעובדים בתיקייה הזו. כדי שיחול על **כל** הפרויקטים, העתק אותו
להגדרות המשתמש:

```bash
mkdir -p ~/.claude
cp .claude/settings.json ~/.claude/settings.json
```

אם כבר קיים `~/.claude/settings.json`, מזג את שני המפתחות לתוכו במקום להחליף.

## אופציונלי: להשאיר skills בלי שייטענו בהתחלה

זה עונה על הבקשה "שהכל יישאר, רק לא ייטען בהתחלה, ו-Claude יפנה לשם כשצריך".
ההגדרה `disable-model-invocation` **לא מוחקת כלום** — היא רק מונעת מ-Claude לטעון את
התיאור בפתיחת הסשן. הפעלה ידנית עם `/שם-הskill` ממשיכה לעבוד רגיל.

הוסף ל-`settings.json` רק אם רוצים (חוסך ~2,100 טוקנים):

```json
{
  "skillOverrides": {
    "learn":                { "disable-model-invocation": true },
    "ai-video-production":  { "disable-model-invocation": true },
    "yourzone-marketing":   { "disable-model-invocation": true },
    "algorithmic-art":      { "disable-model-invocation": true },
    "slack-gif-creator":    { "disable-model-invocation": true },
    "skill-creator":        { "disable-model-invocation": true },
    "internal-comms":       { "disable-model-invocation": true },
    "brand-guidelines":     { "disable-model-invocation": true },
    "theme-factory":        { "disable-model-invocation": true }
  }
}
```

לא הופעל כברירת מחדל — החיסכון קטן יחסית והשינוי משנה התנהגות.

## על ה-Connectors

נותקו Higgsfield (85 כלים) ו-Shopify (26 כלים) דרך claude.ai. זה עוזר, אבל פחות
ממה שנראה: סכימות הכלים של MCP **כבר** נטענות לפי דרישה (מנגנון `ToolSearch`),
ולכן connector מחובר עולה בעיקר את שמות הכלים ואת הוראות השרת — לא את הסכימה המלאה.

Figma נשאר מחובר לפי בקשה.

לניתוק **כל** ה-connectors בבת אחת (לא הופעל — היה חוסם גם את Figma):

```json
{ "disableClaudeAiConnectors": true }
```

## אם זה קורה שוב

ההודעה מופיעה כשההקשר מלא. אם היא חוזרת מיד בפתיחת הטרמינל, כנראה ממשיכים שיחה
ישנה שכבר מלאה — `/clear` פותח שיחה נקייה, `/compact` שומר סיכום של הקודמת.

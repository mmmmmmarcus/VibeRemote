import XCTest
@testable import vvhisper

@MainActor
final class PinyinTests: XCTestCase {
    func testChineseCandidatesDoNotIncludeRawSpellingOrEnglishCompletions() {
        let provider = PinyinCandidates()
        let snapshot = PinyinEngine.Snapshot(input: "haode", commitPreview: "好的", candidates: ["好的", "好"])
        let choices = provider.choices(for: snapshot, letterCase: .lowercase)
        XCTAssertEqual(choices.map(\.text), ["好的", "好"])
        let fallback = provider.choices(for: .init(input: "vvhisper"), letterCase: .initialCapital)
        XCTAssertEqual(fallback.map(\.text), ["Vvhisper"])
    }
    private func action(_ action: PinyinEngine.Action) async -> PinyinEngine.Snapshot {
        await withCheckedContinuation { continuation in
            PinyinEngine.shared.perform(action) { continuation.resume(returning: $0) }
        }
    }
    private func type(_ text: String) async -> PinyinEngine.Snapshot {
        var result = await action(.clear)
        for byte in text.utf8 { result = await action(.key(Int32(byte))) }
        return result
    }
    private func candidates(_ offset: Int, revision: Int) async -> PinyinEngine.CandidateBatch? {
        await withCheckedContinuation { continuation in
            PinyinEngine.shared.candidates(after: offset, revision: revision) { continuation.resume(returning: $0) }
        }
    }

    func testBrowsingPastFirstPagePreservesSpaceAndAbsoluteSelection() async throws {
        let first = await type("shi")
        let start = first.candidates.count
        let fetched = await candidates(start, revision: first.revision)
        let batch = try XCTUnwrap(fetched)
        XCTAssertEqual(batch.offset, start)
        XCTAssertEqual(batch.texts.count, 32)
        let unchanged = await action(.prepare)
        XCTAssertEqual(unchanged.candidates, first.candidates)
        XCTAssertEqual(unchanged.page, 0)
        XCTAssertEqual(unchanged.preedit, first.preedit)
        XCTAssertTrue(unchanged.committed.isEmpty)
        let selected = await action(.chooseAbsolute(start + 4))
        XCTAssertEqual(selected.committed, batch.texts[4])
        XCTAssertTrue(selected.input.isEmpty)

        let again = await type("shi")
        _ = await candidates(again.candidates.count, revision: again.revision)
        let space = await action(.choose(0))
        XCTAssertEqual(space.committed, again.candidates.first)
        let stale = await candidates(start, revision: first.revision)
        XCTAssertNil(stale)
    }

    func testCandidateBrowsingRejectsStaleSameSpellingAndDoesNotSkipBetweenBatches() async throws {
        let old = await type("shi")
        let current = await type("shi")
        let stale = await candidates(0, revision: old.revision)
        XCTAssertNil(stale)
        let fetchedFirst = await candidates(0, revision: current.revision)
        let first = try XCTUnwrap(fetchedFirst)
        XCTAssertEqual(Array(first.texts.prefix(current.candidates.count)), current.candidates)
        let fetchedSecond = await candidates(32, revision: current.revision)
        let second = try XCTUnwrap(fetchedSecond)
        let fetchedBoundary = await candidates(31, revision: current.revision)
        let boundary = try XCTUnwrap(fetchedBoundary)
        XCTAssertEqual(first.texts.last, boundary.texts.first)
        XCTAssertEqual(Array(boundary.texts.dropFirst()), Array(second.texts.prefix(31)))
        _ = await action(.clear)
    }

    func testRealDictionaryConvertsPinyinAndCommitsCandidate() async throws {
        let result = await type("nihao")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.input, "nihao")
        let index = try XCTUnwrap(result.candidates.firstIndex(of: "你好"), "Candidates: \(result.candidates)")
        let chosen = await action(.choose(index))
        XCTAssertEqual(chosen.committed, "你好")
        XCTAssertEqual(chosen.input, "")
    }

    func testPinyinCorrectionOffersMistypedPhrasesWithoutChangingRawInput() async throws {
        for (input, expected) in [("zhdiao", "知道"), ("wozhdiao", "我知道"), ("nihoa", "你好"), ("huanyaun", "还原")] {
            let result = await type(input)
            XCTAssertEqual(result.input, input)
            let choices = PinyinCandidates().choices(for: result, letterCase: .lowercase)
            XCTAssertEqual(choices.first?.text, expected)
            XCTAssertTrue(choices.contains { $0.text == expected }, "\(input): \(choices.map(\.text))")
            if let chosen = choices.first(where: { $0.text == expected }) {
                let committed = await action(chosen.spaceAction)
                XCTAssertEqual(committed.committed, expected)
                XCTAssertTrue(committed.input.isEmpty)
            }
        }
    }


    func testEverydayChinesePhrasesRankFirstAndSpaceCommitsTheDisplayedPhrase() async throws {
        // Exercise real dictionary segmentation and the same candidate/Space path as the keyboard.
        // These are common, unambiguous phrases, including longer forms of the reported failure.
        let phrases = [
            ("wozhidaole", "我知道了"),
            ("wozhidao", "我知道"),
            ("buzhidao", "不知道"),
            ("nizhidaoma", "你知道吗"),
            ("woyijingzhidaole", "我已经知道了"),
            ("wozhidaonizaixiangshenme", "我知道你在想什么"),
            ("wojintianyaoshangban", "我今天要上班"),
            ("woxiangchifan", "我想吃饭"),
            ("womenmingtianjian", "我们明天见"),
            ("wozaikaihui", "我在开会"),
            ("zhegekeyima", "这个可以吗"),
            ("meiyouwenti", "没有问题"),
            ("wojuedekeyi", "我觉得可以"),
            ("dengyixia", "等一下"),
            ("xiexieni", "谢谢你"),
            ("haode", "好的"),
            ("jintiantianqihenhao", "今天天气很好"),
            ("woxianzaiguoqu", "我现在过去"),
            ("woxuyaobangzhu", "我需要帮助"),
            ("zhongwenshurufa", "中文输入法"),
            ("rengongzhineng", "人工智能"),
            ("jintianwanshangchishenme", "今天晚上吃什么"),
            ("nishenmeshihouguolai", "你什么时候过来"),
            ("woyijingdaole", "我已经到了"),
            ("wozhengzaikaiche", "我正在开车"),
            ("zhegezenmeshiyong", "这个怎么使用"),
            ("bangwokanyixia", "帮我看一下"),
            ("womenyihuiliao", "我们一会聊"),
            ("qingwenyoumeiyou", "请问有没有"),
            ("woxiangwenyixia", "我想问一下"),
            ("fangbiandagedianhua", "方便打个电话"),
            ("mingtianzaishuoba", "明天再说吧"),
            ("nishuodeshiduide", "你说的是对的"),
            ("womeitingqingchu", "我没听清楚"),
            ("womenkeyishiyixia", "我们可以试一下"),
            ("wohaiyouyigewenti", "我还有一个问题"),
        ]
        let provider = PinyinCandidates()
        for (spelling, expected) in phrases {
            let snapshot = await type(spelling)
            XCTAssertNil(snapshot.error)
            let first = try XCTUnwrap(provider.choices(for: snapshot, letterCase: .lowercase).first)
            XCTAssertEqual(first.text, expected, "Wrong first candidate for \(spelling)")
            let committed = await action(first.spaceAction)
            XCTAssertEqual(committed.committed, expected, "Wrong Space commit for \(spelling)")
            XCTAssertTrue(committed.input.isEmpty)
        }
    }

    func testDesignVocabularyRanksFirstAndCommitsAsOnePhrase() async throws {
        for (spelling, expected) in [
            ("zoucha", "走查"), ("huanyuan", "还原"), ("shejizoucha", "设计走查"),
            ("shijuehuanyuan", "视觉还原"), ("jiaohusheji", "交互设计"),
            ("shejixitong", "设计系统"), ("zidongbuju", "自动布局"),
            ("zujianbianti", "组件变体"),
            ("weijiaohu", "微交互"), ("chukongrequ", "触控热区")
        ] {
            let snapshot = await type(spelling)
            XCTAssertNil(snapshot.error)
            let first = try XCTUnwrap(PinyinCandidates().choices(for: snapshot, letterCase: .lowercase).first)
            XCTAssertEqual(first.text, expected, spelling)
            let committed = await action(first.spaceAction)
            XCTAssertEqual(committed.committed, expected, spelling)
            XCTAssertTrue(committed.input.isEmpty)
        }
    }

    func testCelebrityNamesAreSelectableOnTheFirstPage() async throws {
        for (spelling, expected) in [
            ("dilireba", "迪丽热巴"), ("zhaolusi", "赵露思"), ("yiyangqianxi", "易烊千玺"),
            ("tanjianci", "檀健次"), ("wangyibo", "王一博"), ("zhoujielun", "周杰伦"),
            ("liudehua", "刘德华")
        ] {
            let snapshot = await type(spelling)
            let index = try XCTUnwrap(snapshot.candidates.firstIndex(of: expected), "\(spelling): \(snapshot.candidates)")
            let committed = await action(.choose(index))
            XCTAssertEqual(committed.committed, expected)
            XCTAssertTrue(committed.input.isEmpty)
        }
    }

    func testEnglishSpellingIsAlwaysAvailableWithoutTranslation() async {
        let result = await type("soundcore")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.input, "soundcore")
        let accepted = await action(.literal)
        XCTAssertEqual(accepted.committed, "soundcore")
        XCTAssertEqual(accepted.input, "")
    }

    func testBackspaceEditsCompositionAndClearDoesNotCommit() async {
        _ = await type("zhongguoo")
        let edited = await action(.key(0xff08))
        XCTAssertEqual(edited.input, "zhongguo")
        XCTAssertTrue(edited.candidates.contains("中国"))
        let cleared = await action(.clear)
        XCTAssertEqual(cleared.input, "")
        XCTAssertEqual(cleared.committed, "")
        XCTAssertTrue(cleared.candidates.isEmpty)
    }

    func testSpaceSelectsChineseAndReturnPathCanKeepLatinSpelling() async {
        _ = await type("nihao")
        let selected = await action(.key(0x20))
        XCTAssertEqual(selected.committed, "你好")
        _ = await type("hello")
        let english = await action(.literal)
        XCTAssertEqual(english.committed, "hello")
        XCTAssertFalse(english.committed.contains("\n"))
    }

    func testEnglishCompletionClearsChineseComposition() async {
        _ = await type("hel")
        let result = await action(.english("hello"))
        XCTAssertEqual(result.committed, "hello")
        XCTAssertTrue(result.input.isEmpty)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testCandidatePagingDoesNotLoseComposition() async {
        let first = await type("shi")
        XCTAssertFalse(first.candidates.isEmpty)
        XCTAssertFalse(first.isLastPage)
        let next = await action(.nextPage)
        XCTAssertEqual(next.input, first.input)
        XCTAssertEqual(next.page, 1)
        XCTAssertNotEqual(next.candidates, first.candidates)
        let previous = await action(.previousPage)
        XCTAssertEqual(previous.candidates, first.candidates)
        _ = await action(.clear)
    }

    func testHaodeFirstVisibleCandidateIsTheSpaceCommitWithoutRawPinyin() async throws {
        let snapshot = await type("haode")
        let choices = PinyinCandidates().choices(for: snapshot, letterCase: .lowercase)
        let first = try XCTUnwrap(choices.first)
        XCTAssertEqual(first.text, "好的")
        XCTAssertFalse(choices.contains { $0.text == "haode" })
        let committed = await action(first.action)
        XCTAssertEqual(committed.committed, first.text)
        XCTAssertTrue(committed.input.isEmpty)
    }

    func testAmbiguousEnglishWordsAndCapitalsStillUseChineseDictionaryOrder() async throws {
        let provider = PinyinCandidates()
        for spelling in ["an", "can", "he", "luma"] {
            let snapshot = await type(spelling)
            XCTAssertFalse(snapshot.candidates.isEmpty)
            for letterCase in [EnglishLetterCase.lowercase, .initialCapital, .uppercase] {
                let choices = provider.choices(for: snapshot, letterCase: letterCase)
                XCTAssertEqual(choices.map(\.text), snapshot.candidates)
            }
            let first = try XCTUnwrap(provider.choices(for: snapshot, letterCase: .lowercase).first)
            let accepted = await action(first.spaceAction)
            XCTAssertEqual(accepted.committed, first.text)
        }
        _ = await action(.clear)
    }
}

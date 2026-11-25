import Testing
@testable import KmsgCore

@Suite("Date separators and time labels")
struct KakaoTextTests {
    @Test("Date separator descriptions become ISO dates")
    func dateSeparators() {
        #expect(KakaoText.dateSeparator("2026년 11월 23일 일요일") == "2026-11-23")
        #expect(KakaoText.dateSeparator("2026년 1월 5일 월요일") == "2026-01-05")
        #expect(KakaoText.dateSeparator("  2025년 12월 31일 수요일 ") == "2025-12-31")
        #expect(KakaoText.dateSeparator("2026년\u{00A0}2월 9일 월요일") == "2026-02-09")
    }

    @Test("Text that only resembles a date separator is rejected")
    func dateSeparatorRejects() {
        #expect(KakaoText.dateSeparator("2026년 13월 5일 월요일") == nil)
        #expect(KakaoText.dateSeparator("26년 1월 5일 월요일") == nil)
        #expect(KakaoText.dateSeparator("11월 23일") == nil)
        #expect(KakaoText.dateSeparator("2026-11-23") == nil)
        #expect(KakaoText.dateSeparator("지난 대화 보기") == nil)
        #expect(KakaoText.dateSeparator("2026년 11월 23일 일요일 오후") == nil)
    }

    @Test("Korean meridiem times convert to 24-hour clock")
    func meridiemTimes() {
        #expect(KakaoText.leadingTime("오후 5:10")?.hhmm == "17:10")
        #expect(KakaoText.leadingTime("오후 5:10")?.raw == "오후 5:10")
        #expect(KakaoText.leadingTime("오전 12:05")?.hhmm == "00:05")
        #expect(KakaoText.leadingTime("오후 12:30")?.hhmm == "12:30")
        #expect(KakaoText.leadingTime("오전 9:07, 안읽음 2")?.hhmm == "09:07")
        #expect(KakaoText.leadingTime("17:45")?.hhmm == "17:45")
        #expect(KakaoText.leadingTime("오후 13:10") == nil)
        #expect(KakaoText.leadingTime("오후 5:1") == nil)
        #expect(KakaoText.leadingTime("12345") == nil)
    }

    @Test("Meta labels: time, unread counter, or both")
    func metaLabels() {
        #expect(KakaoText.isMetaLabel("오후 5:10"))
        #expect(KakaoText.isMetaLabel("안읽음 3"))
        #expect(KakaoText.isMetaLabel("오후 5:10, 안읽음 2"))
        #expect(!KakaoText.isMetaLabel("홍길동"))
        #expect(!KakaoText.isMetaLabel("수정됨"))
        #expect(KakaoText.unreadCount(in: "오후 5:10, 안읽음 2") == 2)
        #expect(KakaoText.unreadCount(in: "안읽음 14") == 14)
        #expect(KakaoText.unreadCount(in: "오후 5:10") == nil)
        #expect(KakaoText.firstTime(in: "안읽음 1, 오후 3:04")?.hhmm == "15:04")
        #expect(KakaoText.firstTime(in: "안읽음 1") == nil)
    }

    @Test("Chat-list helpers")
    func chatListHelpers() {
        #expect(KakaoText.memberCount("9명") == 9)
        #expect(KakaoText.memberCount("1,024명") == 1024)
        #expect(KakaoText.memberCount("9") == nil)
        #expect(KakaoText.isCountLike("3"))
        #expect(KakaoText.isCountLike("999+"))
        #expect(!KakaoText.isCountLike("9명"))
        #expect(KakaoText.isChatListTimeLabel("오후 3:10"))
        #expect(KakaoText.isChatListTimeLabel("어제"))
        #expect(KakaoText.isChatListTimeLabel("11월 23일"))
        #expect(KakaoText.isChatListTimeLabel("2025. 11. 3."))
        #expect(KakaoText.isChatListTimeLabel("오전 9:01, 핀 설정됨"))
        #expect(!KakaoText.isChatListTimeLabel("가족"))
    }
}

import XCTest
@testable import ClaudeNotch

/// Guest appearances are the pet dressing up as something outside itself, and
/// they age: a costume from a particular month should say which month. These pin
/// the split so a new one cannot land without a date, and so the everyday
/// repertoire never quietly loses an animation to the special list.
final class PetSpecialTests: XCTestCase {

    func testTheTwoListsCoverEverythingExactlyOnce() {
        let listed = Set(PetActivity.everydayCases) .union(PetActivity.specialCases)
        let demoable = Set(PetActivity.allCases.filter { $0 != .tucked })
        XCTAssertEqual(listed, demoable,
                       "every animation you can ask to watch belongs to exactly one of the two lists")
        XCTAssertTrue(Set(PetActivity.everydayCases).isDisjoint(with: PetActivity.specialCases),
                      "an animation cannot be both everyday and a guest appearance")
    }

    func testRestingStateIsNotSomethingYouCanWatch() {
        XCTAssertFalse(PetActivity.everydayCases.contains(.tucked),
                       "tucked is the pet being away, not a performance")
        XCTAssertFalse(PetActivity.specialCases.contains(.tucked))
    }

    func testSpiderPetIsAGuestAppearanceWithADate() throws {
        let spider = try XCTUnwrap(PetActivity.spiderHang.special)
        XCTAssertEqual(spider.name, "Spider-Pet")
        XCTAssertEqual(spider.addedOn, "2026-07-15",
                       "the date is the point: it says when the joke is from")
        XCTAssertFalse(spider.reference.isEmpty,
                       "a costume nobody recognises needs a line saying what it is")
    }

    func testEverydayAnimationsCarryNoDate() {
        for activity in PetActivity.everydayCases {
            XCTAssertNil(activity.special,
                         "\(activity.rawValue) is the mascot being itself; it needs no arrival date")
        }
    }

    /// Dates are compared as strings when sorting, which only holds while they
    /// stay zero-padded ISO. A "2026-7-1" would sort wrong and never be noticed.
    func testDatesAreISOSoTheNewestSortsFirst() {
        for activity in PetActivity.specialCases {
            let date = activity.special?.addedOn ?? ""
            XCTAssertEqual(date.count, 10, "\(activity.rawValue): expected yyyy-mm-dd, got \(date)")
            let parts = date.split(separator: "-")
            XCTAssertEqual(parts.count, 3, "\(activity.rawValue): expected yyyy-mm-dd, got \(date)")
            XCTAssertEqual(parts.first?.count, 4)
            XCTAssertTrue(parts.dropFirst().allSatisfy { $0.count == 2 },
                          "\(activity.rawValue): month and day must be zero-padded, got \(date)")
        }
    }

    func testGuestAppearancesAreListedNewestFirst() {
        let dates = PetActivity.specialCases.compactMap { $0.special?.addedOn }
        XCTAssertEqual(dates, dates.sorted(by: >),
                       "the newest costume should be the first one you see")
    }
}

/// The settings row turns the stored ISO date into something readable. It runs
/// on a fixed locale for parsing, so a user in a non-Gregorian calendar still
/// gets a date rather than the raw string.
final class PetSpecialLabelTests: XCTestCase {

    func testISODateBecomesAMonthAndYear() {
        let label = SettingsView.arrivedLabel("2026-07-15")
        XCTAssertTrue(label.hasPrefix("Added "), "got \(label)")
        XCTAssertTrue(label.contains("2026"), "the year is the part that dates the joke, got \(label)")
    }

    func testAMalformedDateShowsItselfRatherThanNothing() {
        XCTAssertEqual(SettingsView.arrivedLabel("someday"), "someday",
                       "a bad date should be visible in the UI, not swallowed into an empty label")
    }
}

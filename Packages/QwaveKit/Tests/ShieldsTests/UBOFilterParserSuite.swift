import Testing
@testable import Shields

/// Swift Testing port of the uBO/EasyList parser cases: table-driven, one
/// test case per filter line.
struct UBOFilterParserSuite {
    static let cases: [(line: String, expected: UBOFilter)] = [
        // Anchored hostname rules.
        ("||example.com^", .hostname(host: "example.com", options: UBOFilterOptions())),
        ("||ads.example.com^$third-party", .hostname(host: "ads.example.com", options: UBOFilterOptions(loadType: "third-party"))),
        ("||example.com^$script,image", .hostname(host: "example.com", options: UBOFilterOptions(resourceTypes: ["script", "image"]))),
        ("||example.com^$domain=a.example|~b.example", .hostname(host: "example.com", options: UBOFilterOptions(domains: ["a.example"], notDomains: ["b.example"]))),
        // Anchored path rules.
        ("||cdn.example.com/banners^", .anchoredPath(host: "cdn.example.com", path: "banners", options: UBOFilterOptions())),
        // Plain host / substring rules.
        ("beacon.example.net", .plain(host: "beacon.example.net", options: UBOFilterOptions())),
        ("/analytics/track.js", .substring(pattern: "/analytics/track.js", options: UBOFilterOptions())),
        // Exceptions.
        ("@@||example.com^", .exception(pattern: "||example.com", options: UBOFilterOptions())),
        // Comments, metadata, cosmetics: ignored.
        ("! comment", .ignore),
        ("[Adblock Plus 2.0]", .ignore),
        ("example.com##.ad-slot", .ignore),
        ("example.com#@#.ad-slot", .ignore),
        ("", .ignore),
    ]

    @Test(arguments: cases)
    func parse(testCase: (line: String, expected: UBOFilter)) {
        #expect(UBOFilterParser.parse(testCase.line) == testCase.expected)
    }

    @Test(arguments: [
        ("third-party", "third-party"),
        ("first-party", "first-party"),
    ])
    func loadTypeOptions(option: String, expected: String) {
        #expect(UBOFilterParser.parseOptions(option).loadType == expected)
    }
}

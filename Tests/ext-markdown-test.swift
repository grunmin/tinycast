import Foundation

/// Guards `ExtensionMarkdown`: block classification, nesting, GFM tables and half-streamed input.
@main
@MainActor
struct ExtensionMarkdownTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        } else {
            print("PASS  \(message)")
        }
    }

    static func parse(_ markdown: String) -> [ExtensionMarkdown.Block] {
        ExtensionMarkdown.parse(markdown)
    }

    static func main() {
        headings()
        paragraphs()
        lists()
        fences()
        tables()
        quotes()
        rules()
        images()
        truncatedInput()

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All extension markdown checks passed")
    }

    static func headings() {
        let blocks = parse(
            """
            # One
            ## Two
            ### Three
            #### Four
            ##### Five
            ###### Six
            ## Seven ##
            #NoSpace
            ####### Too many
            """)
        let levels: [Int] = blocks.compactMap {
            guard case .heading(let level, _) = $0 else { return nil }
            return level
        }
        expect(levels == [1, 2, 3, 4, 5, 6, 2], "headings keep levels 1 through 6")
        expect(blocks.count == 8, "the two non-headings join into one paragraph")
        expect(
            blocks[6] == .heading(level: 2, text: "Seven"), "closing hashes are stripped from the text")
        expect(
            blocks[7] == .paragraph("#NoSpace ####### Too many"),
            "a hash run with no space, or more than six hashes, is text")
        expect(parse("#NoSpace") == [.paragraph("#NoSpace")], "no space after the run is not a heading")
        expect(
            parse("####### Too many") == [.paragraph("####### Too many")],
            "more than six hashes is not a heading")
    }

    static func paragraphs() {
        let blocks = parse(
            """
            First line
            second line
            third line.

            Another paragraph
            wraps too.
            """)
        expect(blocks.count == 2, "a blank line divides paragraphs")
        expect(
            blocks[0] == .paragraph("First line second line third line."),
            "soft-wrapped paragraph lines join")
        expect(
            blocks[1] == .paragraph("Another paragraph wraps too."),
            "the second paragraph joins its lines too")

        let interrupted = parse("Prose\n- a bullet")
        expect(interrupted.count == 2, "a list interrupts a paragraph")
    }

    static func lists() {
        let blocks = parse(
            """
            - parent
              - child
              - second child
            - sibling

            3. three
            4. four

            - [x] done
            - [ ] todo
            - plain
            """)
        expect(blocks.count == 3, "three separate list groups")
        guard case .bulletList(let bullets) = blocks[0] else {
            expect(false, "the first group is a bullet list")
            return
        }
        expect(bullets.count == 2, "nested items do not flatten into the parent list")
        expect(bullets[0].blocks.first == .paragraph("parent"), "a parent item keeps its own text")
        guard bullets[0].blocks.count == 2, case .bulletList(let children) = bullets[0].blocks[1] else {
            expect(false, "an indented item becomes a nested list block")
            return
        }
        expect(children.count == 2, "both nested children are kept")
        expect(children[0].blocks.first == .paragraph("child"), "a nested item keeps its text")

        guard case .numberedList(let start, let numbers) = blocks[1] else {
            expect(false, "the second group is a numbered list")
            return
        }
        expect(start == 3, "a numbered list keeps its start number")
        expect(numbers.count == 2, "a numbered list keeps every item")
        expect(numbers[1].blocks.first == .paragraph("four"), "the second numbered item's text")

        guard case .bulletList(let tasks) = blocks[2] else {
            expect(false, "the third group is a task list")
            return
        }
        expect(tasks.map(\.checked) == [true, false, nil], "task items carry their checked state")
        expect(tasks[0].blocks.first == .paragraph("done"), "a task item keeps its text")
    }

    static func fences() {
        let blocks = parse(
            """
            ```swift
            let x = 1
            ```

            ~~~
            plain text
            ~~~

            ~~~~ruby
            puts "hi"
            ~~~~
            """)
        expect(blocks.count == 3, "three fences")
        expect(
            blocks[0] == .code(language: "swift", text: "let x = 1"),
            "a backtick fence keeps its language")
        expect(
            blocks[1] == .code(language: nil, text: "plain text"),
            "a tilde fence with no info string")
        expect(blocks[2] == .code(language: "ruby", text: #"puts "hi""#), "a longer tilde fence")

        let indented = parse("  ```rust\n  fn main() {}\n  ```")
        expect(
            indented == [.code(language: "rust", text: "fn main() {}")],
            "an indented fence is dedented to its content")
    }

    static func tables() {
        let blocks = parse(
            """
            | Left | Right | Center |
            | :--- | ----: | :----: |
            | a \\| b | 12 | ok |
            | extra | row |
            """)
        guard blocks.count == 1, case .table(let table) = blocks[0] else {
            expect(false, "a GFM table is one block")
            return
        }
        expect(table.header == ["Left", "Right", "Center"], "the header row is split")
        expect(
            table.alignments == [.leading, .trailing, .center],
            "each column reads its alignment from the delimiter")
        expect(table.rows.count == 2, "both body rows are kept")
        expect(table.rows[0] == ["a \\| b", "12", "ok"], "an escaped pipe stays inside its cell")
        expect(table.rows[1] == ["extra", "row", ""], "a ragged row is padded to the header")
        expect(
            parse("| a | b |") == [.paragraph("| a | b |")],
            "a header with no delimiter row is a paragraph")
        expect(
            parse("| a | b |\n| - | - |\n| 1 | 2 |\n\nafter")
                == [
                    .table(
                        .init(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]])),
                    .paragraph("after")
                ],
            "a table closes on a blank line")
    }

    static func quotes() {
        let blocks = parse(
            """
            > outer
            >
            > > inner
            """)
        expect(blocks.count == 1, "a quote is one block")
        guard case .quote(let outer) = blocks[0] else {
            expect(false, "the block is a quote")
            return
        }
        expect(outer.count == 2, "the quote holds its paragraph and its nested quote")
        expect(outer[0] == .paragraph("outer"), "the outer paragraph")
        guard case .quote(let inner) = outer[1] else {
            expect(false, "the inner quote is nested")
            return
        }
        expect(inner == [.paragraph("inner")], "the nested quote's paragraph")

        let quotedList = parse("> - one\n> - two")
        guard case .quote(let items) = quotedList[0], case .bulletList(let list) = items[0] else {
            expect(false, "a list inside a quote stays a list")
            return
        }
        expect(list.count == 2, "the quoted list keeps its items")
    }

    static func rules() {
        let blocks = parse("above\n\n---\n\n***\n\n___\n\nbelow")
        expect(blocks.count == 5, "three rules between two paragraphs")
        expect(blocks[1] == .rule && blocks[2] == .rule && blocks[3] == .rule, "each rule is a rule")
        expect(parse("- - -") == [.rule], "spaced dashes are still one rule")
        expect(parse("--") == [.paragraph("--")], "two dashes are text")
    }

    static func images() {
        let blocks = parse(
            """
            ![cover](https://example.com/a.png?raycast-width=120)

            <img src="https://example.com/b.png" alt="b">

            <img width=10 src='https://example.com/c.png'>

            ![inline](data:image/svg+xml;base64,PHN2Zy8+)

            ![relative](/a.png)

            ![bare](http)
            """)
        let urls: [URL] = blocks.compactMap {
            guard case .image(let url) = $0 else { return nil }
            return url
        }
        expect(urls.count == 4, "four of the six lines are standalone images")
        expect(
            urls.first?.absoluteString == "https://example.com/a.png?raycast-width=120",
            "a markdown image keeps its sizing query")
        expect(
            urls[1].absoluteString == "https://example.com/b.png", "an <img> tag's src is read")
        expect(
            urls[2].absoluteString == "https://example.com/c.png",
            "an <img> tag's src is read among its other attributes")
        expect(urls[3].absoluteString == "data:image/svg+xml;base64,PHN2Zy8+", "a data URL is an image")
        expect(
            parse("![relative](/a.png)") == [.paragraph("![relative](/a.png)")],
            "a relative path stays text")
        expect(
            parse("![unsized](http)") == [.paragraph("![unsized](http)")],
            "a scheme with no host stays text")
    }

    static func truncatedInput() {
        expect(
            parse("```swift\nlet x = 1") == [.code(language: "swift", text: "let x = 1")],
            "an unclosed fence still yields its code")
        expect(
            parse("```").count == 1, "a fence with no body yet is still one block")
        expect(
            parse("- one\n- two").count == 1, "an unclosed list is still a list")
        guard case .bulletList(let open)? = parse("- one\n- two").first else {
            expect(false, "the unclosed list holds bullets")
            return
        }
        expect(open.count == 2, "an unclosed list keeps every item so far")

        guard case .bulletList(let nested)? = parse("- parent\n  - child").first,
            nested.count == 1, nested[0].blocks.count == 2
        else {
            expect(false, "a half-streamed nested list keeps its nesting")
            return
        }
        expect(true, "a half-streamed nested list keeps its nesting")

        guard case .table(let table)? = parse("| a | b |\n| - | - |\n| 1 | 2").first else {
            expect(false, "an unclosed table still yields its rows")
            return
        }
        expect(table.rows.count == 1, "an unclosed table keeps the rows that arrived")

        expect(
            parse("## Title") == [.heading(level: 2, text: "Title")],
            "a heading with no body yet is still a heading")
        expect(
            parse("> quote still open") == [.quote([.paragraph("quote still open")])],
            "an unclosed quote still yields its paragraph")
        expect(
            parse("**bold") == [.paragraph("**bold")],
            "an unclosed emphasis span stays literal text")
        expect(
            parse("![alt](https://exa") == [.paragraph("![alt](https://exa")],
            "a half-written image stays literal text")
        expect(
            parse("- [x") == [.bulletList([.init(blocks: [.paragraph("[x")], checked: nil)])],
            "a half-written task box keeps its bullet")
        expect(parse("") == [], "empty input has no blocks")
    }
}

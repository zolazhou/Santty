// Original manual text/image/animation/AX vectors extracted unchanged from the
// retired lab GUI. Stdout only: no AppKit, process launch, files or VT dependency.
// Run only in an explicitly disposable test terminal, or redirect stdout.
import Foundation
import Darwin

private enum Samples {
    static let images = "\u{1b}[?25lStatic RGBA + PNG transport — Animation fixture is separate\r\n"
            + "Switch Core Graphics / Metal; Reset fixture restores the text sample.\r\n"
            + "\u{1b}[4;3H\u{1b}_Ga=T,f=32,s=2,v=2,i=7,p=3,c=12,r=6,C=1;/wAA/wD/AP8AAP///////w==\u{1b}\\"
            + "\u{1b}[4;22H\u{1b}_Ga=p,i=7,p=4,x=1,w=1,h=2,c=6,r=6,C=1\u{1b}\\"
            + "\u{1b}[4;34H\u{1b}_Ga=T,f=100,i=9,p=1,c=12,r=6,C=1;iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP4z8DAAMIM/4EAAB/uBfsL2WiLAAAAAElFTkSuQmCC\u{1b}\\"
            + "\u{1b}[12;1HLeft: RGBA quadrants. Middle: green / white crop. Right: f=100 PNG quadrants.\r\n"
    static let animation = "\u{1b}[?25lVT-owned animation: red -> green -> blue, 500 ms per frame\r\n"
            + "Hide/occlude this window to suspend ticks; no GIF/APNG decoder.\r\n"
            + "\u{1b}[4;3H\u{1b}_Ga=T,f=32,s=1,v=1,i=7,p=3,c=20,r=10,C=1;/wAA/w==\u{1b}\\"
            + "\u{1b}_Ga=f,f=32,s=1,v=1,i=7,z=500,X=1;AP8A/w==\u{1b}\\"
            + "\u{1b}_Ga=f,f=32,s=1,v=1,i=7,z=500,X=1;AAD//w==\u{1b}\\"
            + "\u{1b}_Ga=a,i=7,r=1,z=500,s=3,c=1,v=1\u{1b}\\\u{1b}[16;1H"
    static let accessibility = "\u{1b}[?2027hAccessibility fixture (read-only AX; native history scrolling)\r\n"
            + "ASCII: alpha beta\r\nWide: 界 😀\r\nCombining: e\u{301}\r\nZWJ: 👩‍👩‍👦\r\n"
            + "Concealed: \u{1b}[8mnot spoken\u{1b}[28m visible\r\n"
            + "\tIndented text\r\nWrap: " + String(repeating: "word ", count: 40)
            + "\r\nEnd. AX setters cannot execute commands or replace terminal text.\r\n"
    static func text(start: Int, count: Int) -> String {
        "\u{1b}[?2027h" + (start..<(start + count)).map { row in
            let links = row % 20 == 19
                ? "  Cmd-hover / Cmd-click: https://example.com/path  \u{1b}]8;;https://example.com/osc8\u{1b}\\OSC 8 label\u{1b}]8;;\u{1b}\\\r\n" : ""
            return "\u{1b}[0m\(row)  \u{1b}[1;32mGhostty VT\u{1b}[0m  中文 👩🏽‍💻 e\u{301}  ─│┼  \u{1b}[3mitalic\u{1b}[0m  \u{1b}[4:3;58:2::255:160:0munderline\u{1b}[0m  \u{1b}[53moverline\u{1b}[55m\r\n" + links
        }.joined()
    }
}

let argument = CommandLine.arguments.dropFirst().first ?? "text"
let payload: String
switch argument {
case "text": payload = Samples.text(start: 0, count: 2_000)
case "images": payload = Samples.images
case "animation": payload = Samples.animation
case "accessibility": payload = Samples.accessibility
case "--help", "-h":
    print("Usage: xcrun swift Scripts/Terminal/print-sample.swift [text|images|animation|accessibility]")
    exit(0)
default:
    FileHandle.standardError.write(Data("Unknown sample: \(argument)\n".utf8))
    exit(2)
}
FileHandle.standardOutput.write(Data(payload.utf8))

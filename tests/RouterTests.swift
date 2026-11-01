import Foundation

/// Just the parts of Workflow the router reads.
struct Workflow { var name: String; var steps: [Int]; var defaults: [String: String]? }

@main struct RouterTests {
    static func main() {
        // Two slots whose values differ in length: the longer one comes SECOND in the sentence.
        let wf = Workflow(name: "send hi to Bob from Alexandria", steps: [1], defaults: ["recipient": "Bob", "sender": "Alexandria"])
        guard let m = Router.match("send hi to Carol from Zed", in: [wf]) else { fatalError("no match") }
        precondition(m.params["recipient"] == "Carol", "recipient captured \(m.params["recipient"] ?? "nil")")
        precondition(m.params["sender"] == "Zed", "sender captured \(m.params["sender"] ?? "nil")")
        // Longer value first in the sentence.
        let wf2 = Workflow(name: "copy Quarterly Report to Bob", steps: [1], defaults: ["file": "Quarterly Report", "who": "Bob"])
        let m2 = Router.match("copy Annual Plan to Dana", in: [wf2])
        precondition(m2?.params["file"] == "Annual Plan" && m2?.params["who"] == "Dana", "got \(String(describing: m2?.params))")
        // A request that does not fit the template is left to the model.
        precondition(Router.match("delete everything", in: [wf]) == nil)
        print("PASS router captures slots in textual order")
    }
}

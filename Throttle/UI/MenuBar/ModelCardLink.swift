import SwiftUI

struct ModelCardLink: View {
    let title: LocalizedStringKey
    let url: URL?

    var body: some View {
        if let url { Link(title, destination: url) }
    }
}

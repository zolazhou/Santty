import AppKit
import SwiftUI

struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                content
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(.rect(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsRow<Content: View, Description: View>: View {
    let title: String
    let content: Content
    let description: Description

    init(
        _ title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder description: () -> Description
    ) {
        self.title = title
        self.content = content()
        self.description = description()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .frame(width: 150, alignment: .leading)

                content
            }
            .frame(minHeight: 38)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            description
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 14)
        }
    }
}

extension SettingsRow where Description == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        description = EmptyView()
    }
}

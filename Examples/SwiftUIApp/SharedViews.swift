//
//  SharedViews.swift
//  SwiftUIApp
//
//  共通のビューコンポーネント
//  Shared view components
//

import SwiftUI

// MARK: - Info Row

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}
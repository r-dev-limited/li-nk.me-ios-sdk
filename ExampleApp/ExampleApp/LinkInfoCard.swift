import SwiftUI
import LinkMeKit

struct LinkInfoCard: View {
    let payload: LinkPayload?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last Link Payload")
                .font(.headline)
            
            if let payload = payload {
                VStack(alignment: .leading, spacing: 8) {
                    if let linkId = payload.linkId {
                        InfoRow(label: "Link ID", value: linkId)
                    }
                    
                    if let path = payload.path {
                        InfoRow(label: "Path", value: path)
                    }
                    
                    if let params = payload.params, !params.isEmpty {
                        Text("Params:")
                            .font(.caption)
                            .bold()
                        ForEach(Array(params.keys.sorted()), id: \.self) { key in
                            InfoRow(label: key, value: params[key] ?? "")
                                .padding(.leading)
                        }
                    }
                    
                    if let utm = payload.utm, !utm.isEmpty {
                        Text("UTM:")
                            .font(.caption)
                            .bold()
                        ForEach(Array(utm.keys.sorted()), id: \.self) { key in
                            InfoRow(label: key, value: utm[key] ?? "")
                                .padding(.leading)
                        }
                    }
                    
                    if let custom = payload.custom, !custom.isEmpty {
                        Text("Custom:")
                            .font(.caption)
                            .bold()
                        ForEach(Array(custom.keys.sorted()), id: \.self) { key in
                            InfoRow(label: key, value: custom[key] ?? "")
                                .padding(.leading)
                        }
                    }
                }
            } else {
                Text("No link received yet")
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text("\(label):")
                .font(.caption)
                .bold()
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}


import SwiftUI
import LinkMeKit

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var userId: String = ""
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("LinkMe Example")
                    .font(.largeTitle)
                    .bold()
                
                LinkInfoCard(payload: appState.lastPayload)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("SDK Features")
                        .font(.headline)
                    
                    Button("Track Event: 'button_click'") {
                        LinkMe.shared.track(event: "button_click", props: ["screen": "home"])
                    }
                    .modifier(ButtonStyleModifier())
                    
                    Button("Track Event: 'test_event'") {
                        LinkMe.shared.track(event: "test_event", props: ["feature": "home"])
                    }
                    .modifier(ButtonStyleModifier())
                    
                    if !userId.isEmpty {
                        Button("Clear User ID") {
                            userId = ""
                            LinkMe.shared.setUserId("")
                        }
                        .modifier(ButtonStyleModifier())
                    } else {
                        HStack {
                            TextField("Enter User ID", text: $userId)
                                .textFieldStyle(.roundedBorder)
                            Button("Set") {
                                LinkMe.shared.setUserId(userId)
                            }
                            .modifier(ButtonStyleModifier())
                        }
                    }
                    
                    Button("Claim Deferred Link") {
                        LinkMe.shared.claimDeferredIfAvailable { payload in
                            DispatchQueue.main.async {
                                appState.lastPayload = payload
                                if let path = payload?.path {
                                    appState.navigateToPath(path)
                                }
                            }
                        }
                    }
                    .modifier(ButtonStyleModifier())
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                
                if #available(iOS 16, *) {
                    NavigationLink(value: "profile") {
                        Text("Go to Profile")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    NavigationLink(destination: ProfileView()) {
                        Text("Go to Profile")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                
                if #available(iOS 16, *) {
                    NavigationLink(value: "settings") {
                        Text("Go to Settings")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    NavigationLink(destination: SettingsView()) {
                        Text("Go to Settings")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue, lineWidth: 1))
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Home")
    }
}


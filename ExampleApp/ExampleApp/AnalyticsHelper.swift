import Foundation
import LinkMeKit

// NOTE: Import your analytics SDKs here
// import FirebaseAnalytics
// import PostHog

/**
 * A helper struct demonstrating how to map LinkMe payloads to various analytics providers.
 *
 * NOTE: This file contains commented-out code for the actual SDK calls.
 * You should uncomment the relevant sections after adding the corresponding dependencies (CocoaPods/SPM).
 */
struct AnalyticsHelper {
    
    static func logToAnalytics(payload: LinkPayload) {
        guard let utm = payload.utm else { return }
        
        print("[AnalyticsHelper] Received LinkMe Payload with UTM: \(utm)")
        
        // 1. Log to Firebase Analytics (Google Analytics 4)
        logToFirebase(payload: payload)
        
        // 2. Log to PostHog
        logToPostHog(payload: payload)
    }
    
    private static func logToFirebase(payload: LinkPayload) {
        guard let utm = payload.utm else { return }
        
        /*
        var params: [String: Any] = [:]
        
        // Map standard UTM keys to Firebase constants
        // Note: Firebase uses specific parameter names (kFIRParameterSource, etc.)
        if let source = utm["utm_source"] { params[AnalyticsParameterSource] = source }
        if let medium = utm["utm_medium"] { params[AnalyticsParameterMedium] = medium }
        if let campaign = utm["utm_campaign"] { params[AnalyticsParameterCampaign] = campaign }
        if let term = utm["utm_term"] { params[AnalyticsParameterTerm] = term }
        if let content = utm["utm_content"] { params[AnalyticsParameterContent] = content }
        
        if let linkId = payload.linkId { params["link_id"] = linkId }
        
        // Log the standard campaign_details event
        Analytics.logEvent(AnalyticsEventCampaignDetails, parameters: params)
        */
        
        print("[MOCK] Firebase Analytics.logEvent(AnalyticsEventCampaignDetails, parameters: \(utm))")
    }
    
    private static func logToPostHog(payload: LinkPayload) {
        guard let utm = payload.utm else { return }
        
        /*
        // Option A: Identify (Attribution)
        // PostHog.shared.identify("user_123", userProperties: utm)
        
        // Option B: Capture Event
        var properties = utm
        if let linkId = payload.linkId { properties["link_id"] = linkId }
        if let path = payload.path { properties["path"] = path }
        
        PostHogSDK.shared.capture("Deep Link Opened", properties: properties)
        */
        
        print("[MOCK] PostHog capture('Deep Link Opened', properties: \(utm))")
    }
}

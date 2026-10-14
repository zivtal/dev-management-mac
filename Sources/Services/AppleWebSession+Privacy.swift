import Foundation
import WebKit

extension AppleWebSession {
    /// Called only after the existing per-app privacy review and authorization.
    /// Never replaces a collected-data declaration with a no-data declaration.
    func publishPrivacy(draft: AppStorePrivacyDraft, appID: String, bundleIdentifier: String) async throws {
        _ = try AppStorePrivacyPublishingService.payload(for: draft)
        guard canUseSession else {
            throw AppStoreConnectError.requestFailed(401, L10n.text("Sign in to Apple and select the correct team first."))
        }
        let result = try await webView.callAsyncJavaScript("""
            async function request(path, method = 'GET', data) {
                const response = await fetch('/iris/v1/' + path, {
                    method, credentials: 'same-origin',
                    headers: {'Content-Type': 'application/vnd.api+json', Accept: 'application/json'},
                    body: data ? JSON.stringify({data}) : undefined
                });
                const body = await response.json();
                if (!response.ok) throw new Error((body.errors || []).map(e => e.detail || e.title).join('; ') || 'Apple request failed: ' + response.status);
                return body.data;
            }
            const app = await request('apps/' + encodeURIComponent(appID));
            if (app.attributes.bundleId !== bundleID) throw new Error('The Apple web session does not match the selected app and API account.');
            const usages = await request('apps/' + encodeURIComponent(appID) + '/dataUsages?include=dataProtection');
            if (usages.some(u => u.relationships?.dataProtection?.data?.id !== 'DATA_NOT_COLLECTED')) {
                throw new Error('Existing App Privacy answers describe collected data. Review them on Apple’s page; nothing was replaced.');
            }
            if (!usages.length) {
                await request('appDataUsages', 'POST', {type: 'appDataUsages', relationships: {
                    app: {data: {type: 'apps', id: appID}},
                    dataProtection: {data: {type: 'appDataUsageDataProtections', id: 'DATA_NOT_COLLECTED'}}
                }});
            }
            const state = await request('apps/' + encodeURIComponent(appID) + '/dataUsagePublishState');
            if (!state.attributes.published) {
                await request('appDataUsagesPublishState/' + encodeURIComponent(state.id), 'PATCH', {
                    type: 'appDataUsagesPublishState', id: state.id, attributes: {published: true}
                });
            }
            const verified = await request('apps/' + encodeURIComponent(appID) + '/dataUsagePublishState');
            return verified.attributes.published === true;
            """, arguments: ["appID": appID, "bundleID": bundleIdentifier], in: nil, contentWorld: .page)
        guard result as? Bool == true else {
            throw AppStoreConnectError.requestFailed(0, L10n.text("Apple did not confirm App Privacy publication. Review the declaration on Apple’s page, then retry."))
        }
    }
}

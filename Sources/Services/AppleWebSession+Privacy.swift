import Foundation
import WebKit

extension AppleWebSession {
    /// Called only after the existing per-app privacy review and authorization.
    /// Publishes the planned usage records: nothing happens when Apple already holds
    /// exactly those answers, a no-data declaration never replaces collected-data
    /// answers, and a reviewed collected-data declaration replaces whatever differs.
    /// Returns the number of records created.
    @discardableResult
    func publishPrivacy(draft: AppStorePrivacyDraft, appID: String, bundleIdentifier: String) async throws -> Int {
        let records = try AppStorePrivacyUsagePlan.records(for: draft)
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
                if (response.status === 204) return null;
                const body = await response.json();
                if (!response.ok) throw new Error((body.errors || []).map(e => e.detail || e.title).join('; ') || 'Apple request failed: ' + response.status);
                return body.data;
            }
            const key = r => [r.category || '', r.purpose || '', r.dataProtection].join('|');
            const app = await request('apps/' + encodeURIComponent(appID));
            if (app.attributes.bundleId !== bundleID) throw new Error('The Apple web session does not match the selected app and API account.');
            const existing = await request('apps/' + encodeURIComponent(appID) + '/dataUsages?include=category,purpose,dataProtection&limit=500');
            const existingKeys = new Set(existing.map(u => key({
                category: u.relationships?.category?.data?.id,
                purpose: u.relationships?.purpose?.data?.id,
                dataProtection: u.relationships?.dataProtection?.data?.id
            })));
            const plannedKeys = new Set(records.map(key));
            const matches = existingKeys.size === plannedKeys.size && [...plannedKeys].every(k => existingKeys.has(k));
            const plannedNoData = records.length === 1 && records[0].dataProtection === 'DATA_NOT_COLLECTED';
            const existingCollects = existing.some(u => u.relationships?.dataProtection?.data?.id !== 'DATA_NOT_COLLECTED');
            let created = 0;
            if (!matches) {
                if (plannedNoData && existingCollects) {
                    throw new Error('Existing App Privacy answers describe collected data. Review them on Apple’s page; nothing was replaced.');
                }
                for (const usage of existing) await request('appDataUsages/' + encodeURIComponent(usage.id), 'DELETE');
                for (const record of records) {
                    const relationships = {
                        app: {data: {type: 'apps', id: appID}},
                        dataProtection: {data: {type: 'appDataUsageDataProtections', id: record.dataProtection}}
                    };
                    if (record.category) relationships.category = {data: {type: 'appDataUsageCategories', id: record.category}};
                    if (record.purpose) relationships.purpose = {data: {type: 'appDataUsagePurposes', id: record.purpose}};
                    await request('appDataUsages', 'POST', {type: 'appDataUsages', relationships});
                    created += 1;
                }
            }
            const state = await request('apps/' + encodeURIComponent(appID) + '/dataUsagePublishState');
            if (!state.attributes.published) {
                await request('appDataUsagesPublishState/' + encodeURIComponent(state.id), 'PATCH', {
                    type: 'appDataUsagesPublishState', id: state.id, attributes: {published: true}
                });
            }
            const verified = await request('apps/' + encodeURIComponent(appID) + '/dataUsagePublishState');
            return {published: verified.attributes.published === true, created};
            """, arguments: [
                "appID": appID, "bundleID": bundleIdentifier,
                "records": AppStorePrivacyUsagePlan.scriptArguments(records)
            ], in: nil, contentWorld: .page)
        guard let result = result as? [String: Any], result["published"] as? Bool == true else {
            throw AppStoreConnectError.requestFailed(0, L10n.text("Apple did not confirm App Privacy publication. Review the declaration on Apple’s page, then retry."))
        }
        return result["created"] as? Int ?? 0
    }
}

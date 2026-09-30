//
//  PreviewProvider.swift
//  QuickLookAPKPreview
//
//  Created by Roman on 7. 7. 2026.
//

import Quartz

class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    
    /// Returns the HTML preview page for the APK.
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        guard let apk = AndroidPackage(path: request.fileURL.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        
        let htmlData = Data(androidPackageHTMLPreview(apk).utf8)
        
        let reply = QLPreviewReply.init(
            dataOfContentType: .html,
            contentSize: CGSize.init(width: 800, height: 800)
        ) {(replyToUpdate : QLPreviewReply) in
            
            replyToUpdate.stringEncoding = .utf8
            
            return htmlData
        }
        return reply
    }
}

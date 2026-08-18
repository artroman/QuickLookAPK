//
//  PreviewProvider.swift
//  QuickLookAPKPreview
//
//  Created by Roman on 7. 7. 2026..
//

import Quartz

class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    
    /*
     Use a QLPreviewProvider to provide data-based previews.
     
     To set up your extension as a data-based preview extension:

     - Modify the extension's Info.plist by setting
       <key>QLIsDataBasedPreview</key>
       <true/>
     
     - Add the supported content types to QLSupportedContentTypes array in the extension's Info.plist.

     - Change the NSExtensionPrincipalClass to this class.
       e.g.
       <key>NSExtensionPrincipalClass</key>
       <string>$(PRODUCT_MODULE_NAME).PreviewProvider</string>
     
     - Implement providePreview(for:)
     */
    
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        guard let apk = AndroidPackage(path: request.fileURL.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        
        let htmlData = Data(androidPackageHTMLPreview(apk).utf8)
        
        //You can create a QLPreviewReply in several ways, depending on the format of the data you want to return.
        //To return Data of a supported content type:
        let reply = QLPreviewReply.init(
            dataOfContentType: .html,
            contentSize: CGSize.init(width: 800, height: 800)
        ) {(replyToUpdate : QLPreviewReply) in
            
            //setting the stringEncoding for text and html data is optional and defaults to String.Encoding.utf8
            replyToUpdate.stringEncoding = .utf8
            
            return htmlData
        }
        return reply
    }
}

//
//  ThumbnailProvider.swift
//  QuickLookAPKThumbnail
//
//  Created by Roman on 7. 7. 2026.
//

import QuickLookThumbnailing
import AppKit

class ThumbnailProvider: QLThumbnailProvider {
    
    /// Draws the APK's app icon, unmasked and aspect-fit, as the Finder thumbnail.
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        
        guard let apk = AndroidPackage(path: request.fileURL.path, iconOnly: true, masksAdaptiveIcon: false),
              !apk.iconData.isEmpty,
              let icon = NSImage(data: apk.iconData),
              icon.size.width > 0, icon.size.height > 0
        else {
            handler(nil, QLThumbnailError(.generationFailed))
            return
        }

        // Aspect-fit the icon into the requested bounds rather than stretching it.
        let maximumSize = request.maximumSize
        let scale = min(maximumSize.width / icon.size.width, maximumSize.height / icon.size.height)
        let size = CGSize(width: (icon.size.width * scale).rounded(), height: (icon.size.height * scale).rounded())

        handler(QLThumbnailReply(contextSize: size, currentContextDrawing: { () -> Bool in
            icon.draw(in: NSRect(origin: .zero, size: size),
                      from: NSRect.zero,
                      operation: NSCompositingOperation.sourceOver,
                      fraction: 1.0)
            
            return true
        }), nil)
    }
}

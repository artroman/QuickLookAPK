//
//  ThumbnailProvider.swift
//  QuickLookAPKThumbnail
//
//  Created by Roman on 7. 7. 2026..
//

import QuickLookThumbnailing
import AppKit

class ThumbnailProvider: QLThumbnailProvider {
    
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard let apk = HZAndroidPackage(path: request.fileURL.path),
              let iconData = apk.iconData, !iconData.isEmpty,
              let icon = NSImage(data: iconData) else {
            handler(nil, QLThumbnailError(.generationFailed))
            return
        }
        
        let size = request.maximumSize
        let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
            icon.draw(in: NSRect(origin: .zero, size: size),
                      from: NSRect.zero,
                      operation: NSCompositingOperation.sourceOver,
                      fraction: 1.0)
            return true
        }
        handler(reply, nil)
    }
}

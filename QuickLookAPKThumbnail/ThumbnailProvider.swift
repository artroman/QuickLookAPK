//
//  ThumbnailProvider.swift
//  QuickLookAPKThumbnail
//
//  Created by Roman on 7. 7. 2026.
//

import QuickLookThumbnailing
import AppKit

class ThumbnailProvider: QLThumbnailProvider {
    
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // There are three ways to provide a thumbnail through a QLThumbnailReply. Only one of them should be used.
        
        guard let apk = AndroidPackage(path: request.fileURL.path),
              !apk.iconData.isEmpty,
              let icon = NSImage(data: apk.iconData) else {
            handler(nil, QLThumbnailError(.generationFailed))
            return
        }
        
        let size = request.maximumSize
        
        // First way: Draw the thumbnail into the current context, set up with UIKit's coordinate system.
        handler(QLThumbnailReply(contextSize: size, currentContextDrawing: { () -> Bool in
            // Draw the thumbnail here.
            icon.draw(in: NSRect(origin: .zero, size: size),
                      from: NSRect.zero,
                      operation: NSCompositingOperation.sourceOver,
                      fraction: 1.0)
            
            // Return true if the thumbnail was successfully drawn inside this block.
            return true
        }), nil)
        
        /*
        // Second way: Draw the thumbnail into a context passed to your block, set up with Core Graphics's coordinate system.
        handler(QLThumbnailReply(contextSize: request.maximumSize, drawing: { (context) -> Bool in
        // Draw the thumbnail here.
        
        // Return true if the thumbnail was successfully drawn inside this block.
        return true
        }), nil)
        
        // Third way: Set an image file URL.
        handler(QLThumbnailReply(imageFileURL: Bundle.main.url(forResource: "fileThumbnail", withExtension: "jpg")!), nil)
        */
    }
}

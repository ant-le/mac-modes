import Foundation
import CoreText
import MacModesCore
final class PlatformTests {
    func testVPNGates() throws {
        for v6 in [nil,"utun4"] as [String?] { expectNoThrow(try MacPlatform.validateVPN(connected:true,tailscale:"Stopped",ipv4:"utun4",ipv6:v6,egress:"{\"Code\":86081}")) }
        for (connected,ts,v4,v6,response) in [(false,"Stopped","utun4",nil,"{\"Code\":86081}"),(true,"Running","utun4",nil,"{\"Code\":86081}"),(true,"Stopped","en0",nil,"{\"Code\":86081}"),(true,"Stopped","utun4","en0","{\"Code\":86081}"),(true,"Stopped","utun4",nil,"{\"Code\":1000}")] as [(Bool,String,String,String?,String)] {
            expectThrows(try MacPlatform.validateVPN(connected:connected,tailscale:ts,ipv4:v4,ipv6:v6,egress:response))
        }
    }
    func testUnknownProtonStatePreserved() throws {
        let result=try MacPlatform.parseProton("* (Reasserting) ABCDEF01-2345-6789-ABCD-0123456789AB VPN ProtonVPN")
        expectEqual(result.count,1);expectEqual(result.first?.1,"Reasserting")
    }
    func testCommandTimeoutAndFailure() throws {
        try expectEqual(try command(["/bin/echo","hello"]).output,"hello")
        expectThrows(try command(["/usr/bin/false"]))
        expectThrows(try command(["/bin/sleep","2"],timeout:0.05))
    }
    func testOCRReadsGeneratedImage() throws {
        let context=CGContext(data:nil,width:1000,height:180,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:1000,height:180))
        let attributes: [NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,48,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)]
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:"Mac Modes OCR 12345",attributes:attributes))
        context.textPosition=CGPoint(x:30,y:70);CTLineDraw(line,context)
        let text=try recognizeText(in:context.makeImage()!)
        expectTrue(text.contains("Mac Modes"));expectTrue(text.contains("12345"))
    }
}

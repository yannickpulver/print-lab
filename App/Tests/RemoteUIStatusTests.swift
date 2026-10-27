import Foundation
import Testing
@testable import PrintLab

/// Snippets in the format of the PRO-1000's Remote UI (firmware 4.000).
struct RemoteUIStatusTests {
    static let table = """
    var edmInstanceAry = {
    HTTP_ERR_DISP_IDLE: new ErrDtlMsg({ errmsg: '' }),
    HTTP_ERR_DISP_DOC_1200: new ErrDtlMsg({ errmsg: 'MES0243' }),
    HTTP_ERR_DISP_DOC_ETC: new ErrDtlMsg({ errmsg: 'MES0268' }),
    """
    static let texts = """
    var Eng = {
    MES0243: "The printer's cover is open. Close the cover.",
    MES0268: "Operator error has occurred.",
    """

    static func model(state: String, doc: String, id: String) -> String {
        """
        var g_err_url = 'http://rs.ciggws.net/rd.cgi?FNC=RUI_ERR&amp;DEV=PRO-1000+series&amp;ERR=1250';
        var g_signal_strength = '76';
        var g_link_quality = '84';
        var g_err_msg_id = '\(id)';
        var g_bst_st = '\(state)';
        var g_prndoc = '\(doc)';
        """
    }

    let messages = RemoteUIStatus.messages(errorTable: table, texts: texts)

    @Test func idlePrinterHasNoErrorButSignal() {
        let status = RemoteUIStatus.parse(modelJS: Self.model(state: "0", doc: "0", id: "HTTP_ERR_DISP_IDLE"),
                                          messages: messages)
        #expect(status.error == nil)
        #expect(status.signal == 76)
        #expect(status.linkQuality == 84)
    }

    @Test func printerInOperationIsNoError() {
        // State 2 while printing, also while the printer waits for a sheet in the manual feed.
        let status = RemoteUIStatus.parse(modelJS: Self.model(state: "2", doc: "0", id: "HTTP_ERR_DISP_IDLE"),
                                          messages: messages)
        #expect(status.error == nil)
    }

    @Test func supportCodeIsPrndocInHex() {
        // 4688 = 0x1250: the closed output tray seen on the real printer.
        let status = RemoteUIStatus.parse(modelJS: Self.model(state: "3", doc: "4688", id: "HTTP_ERR_DISP_DOC_ETC"),
                                          messages: messages)
        #expect(status.error?.code == "1250")
        #expect(status.error?.message == "The paper output tray is closed. Open the output tray.")
        #expect(status.error?.helpURL?.absoluteString.contains("&ERR=1250") == true)
    }

    @Test func usesPrinterMessageWhenThereIsNoHint() {
        let status = RemoteUIStatus.parse(modelJS: Self.model(state: "3", doc: "4608", id: "HTTP_ERR_DISP_DOC_1200"),
                                          messages: messages)
        #expect(status.error?.code == "1200")
        #expect(status.error?.message == "The printer's cover is open. Close the cover.")
    }
}

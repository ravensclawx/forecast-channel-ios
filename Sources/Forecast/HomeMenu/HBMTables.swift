/// Binding tables of the RVL SDK HOME Button Menu (see decomp/notes/homemenu.md).
enum HBMTables {
    static let animPrefix = "th_HomeBtn_c"
    static let layoutName = "th_HomeBtn_c.brlyt"

    /// Big-button anims (lbl_801B4900 suffixes) and groups (lbl_801B48AC).
    static let btnAnimSuffix = ["cntBtn_in", "cntBtn_psh", "cntBtn_out"]
    static let btnGroups = ["btnL_00_inOut", "btnL_01_inOut", "btnL_10_inOut", "btnL_11_inOut",
                            "btnL_00_psh", "btnL_01_psh", "btnL_10_psh", "btnL_11_psh"]
    /// lbl_80193DC8: (group, anim) per big button: in, out, psh.
    static let btnPairs: [(Int, Int)] = [(0, 0), (0, 2), (4, 1), (1, 0), (1, 2), (5, 1), (2, 0), (2, 2), (6, 1), (3, 0), (3, 2), (7, 1)]

    /// 15 one-to-one anims (lbl_801B4A48 suffix == lbl_801B4B5C group).
    static let oneToOne = ["ltrIcn_on", "optn_bar_psh", "close_bar_psh", "hmMenu_bar_in", "hmMenu_bar_psh", "link_msg_in",
                           "link_msg_out", "cmn_msg_in", "cmn_msg_out", "cntrl_up", "cntrl_wndw_opn", "cntrl_dwn",
                           "hmMenu_bar_out", "cmn_msg_rtrn", "12btn_on"]

    /// Group index space for the 74-pair table.
    static let groups: [String] = ["hmMenu_strt", "hmMenu_fnsh", "hmMenuBck_strt", "hmMenuBck_fnsh", "optn_bar_in", "optn_bar_out",
                                   "optnBtn_00_inOut", "optnBtn_01_inOut", "optnBtn_10_inOut", "optnBtn_11_inOut", "optnBtn_20_inOut",
                                   "optnBtn_00_psh", "optnBtn_01_psh", "optnBtn_10_psh", "optnBtn_11_psh", "optnBtn_20_psh",
                                   "optnBtn_10_cntrl", "msgBtn_00_inOut", "msgBtn_01_inOut", "msgBtn_00_psh", "msgBtn_01_psh"]
        + (0..<10).map { String(format: "vol_%02d", $0) } + (0..<4).map { String(format: "plyr_%02d", $0) }
    /// Anim index space (lbl_801B4D68).
    static let anims = ["hmMenu_strt", "hmMenu_fnsh", "optn_bar_in", "optn_bar_out", "optn_btn_in", "optn_btn_psh",
                        "vb_btn_wht_psh", "optn_btn_out", "vb_btn_ylw_psh", "sound_gry", "sound_ylw", "cmn_msg_btn_in",
                        "cmn_msg_btn_out", "cmn_msg_btn_psh", "vb_btn_ylw_ylw", "btry_wink", "btry_gry", "btry_wht",
                        "btry_wink_gry", "close_bar_in", "close_bar_out", "btry_red"]
    /// lbl_80193E28: (group, anim) × 74.
    static let pairs: [(Int, Int)] = [(0, 0), (1, 1), (2, 0), (3, 1), (4, 2), (4, 19), (5, 3), (5, 20), (6, 4), (6, 7), (7, 4), (7, 7), (8, 4), (8, 7),
        (9, 4), (9, 7), (10, 4), (10, 7), (11, 5), (12, 5), (13, 6), (13, 8), (14, 14), (14, 6), (14, 8), (15, 5), (16, 6), (16, 14),
        (17, 11), (17, 12), (18, 11), (18, 12), (19, 13), (20, 13), (21, 9), (21, 10), (22, 9), (22, 10), (23, 9), (23, 10), (24, 9),
        (24, 10), (25, 9), (25, 10), (26, 9), (26, 10), (27, 9), (27, 10), (28, 9), (28, 10), (29, 9), (29, 10), (30, 9), (30, 10),
        (31, 15), (31, 16), (31, 17), (31, 18), (31, 21), (32, 15), (32, 16), (32, 17), (32, 18), (32, 21), (33, 15), (33, 16),
        (33, 17), (33, 18), (33, 21), (34, 15), (34, 16), (34, 17), (34, 18), (34, 21)]

    /// fn_8007AEC8 bounding order after the big buttons (lbl_801B5080).
    static let bigButtons = ["B_btnL_00", "B_btnL_01", "B_btnL_10"]
    static let bounds = ["B_btn_00", "B_bar_10", "B_optnBtn_00", "B_optnBtn_01", "B_optnBtn_10", "B_optnBtn_11", "B_optnBtn_20", "cntrl_00"]
    static let dialogButtons = ["B_BtnA", "B_BtnB"]

    /// HOMESE_* ids in Huf8_HomeButtonSe.brsar.
    enum SE: Int {
        case homeButton = 0, returnApp, gotoMenu, resetApp, focus, select, cancel, openController, closeController,
             volumePlus, volumeMinus, volumePlusLimit, volumeMinusLimit, nothingDone, vibeOn, vibeOff,
             startConnectWindow, connected, connected2, connected3, connected4, endConnectWindow
    }
}

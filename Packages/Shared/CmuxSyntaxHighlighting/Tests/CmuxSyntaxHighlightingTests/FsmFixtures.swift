// Real engine outputs for FsmModelTests, recorded 2026-11-01 from the fixture in
// scripts/waveform-viewer-checks/fsm/ (fsm_pkg.sv, dut.sv, tb.sv):
// - Verdi W-2024.09 on a VCS -kdb build, through Resources/vaporview/fsm/cmux-fsm-verdi.sh
//   (only the report it prints between its report markers);
// - Yosys 0.70+286 (OSS CAD Suite 2026-11-01, read_slang) `write_json`, cut down to the $fsm cells and the nets
//   they connect to.
enum FsmFixtures {
    static let verdiCtl = #"""
    Finite State Machine (ctl) Report
    ---------------------------------------------
    Input Signals:
    	clk:Clock
    	go:Control
    	rst:Control
    	stall:Control
    
    Output Signals:
    	next_state[2:0]:Output
    	state[2:0]:Output
    
    Clock Signal:clk
    Clock Polarity:Rising
    Reset Condition1:rst
    State Signal:state[2:0]
    Initial State:IDLE
    State Table:
    	IDLE=3'b000
    	FETCH=3'b001
    	DECODE=3'b100
    	EXEC=3'b101
    	DONE=3'b111
    	Others=Others
    =============================================
    = Detail State Report                       =
    =============================================
    Others	StateType:
        Transitions:
    	 ->IDLE	
    
        State Outputs:
    
    ---------------------------------------------
    DONE	StateType:
        Transitions:
    	 ->IDLE	
    
        State Outputs:
    
    ---------------------------------------------
    EXEC	StateType:
        Transitions:
    	 ->FETCH	go
    
    	 ->DONE	!go
    
        State Outputs:
    
    ---------------------------------------------
    DECODE	StateType:
        Transitions:
    	 ->EXEC	!stall
    
        State Outputs:
    
    ---------------------------------------------
    FETCH	StateType:
        Transitions:
    	 ->DECODE	
    
        State Outputs:
    
    ---------------------------------------------
    IDLE	StateType:
        Transitions:
    	 ->FETCH	go
    
        State Outputs:
    
    ---------------------------------------------
    State Report
    ---------------------------------------------
    // <<Format>>
    //     state_name: state_count
    	(Trap State): 1
    	DECODE: 26
    	DONE: 3
    	EXEC: 10
    	FETCH: 11
    	IDLE: 11
    	Others: 0
    
    =============================================
    = Warning !!! Untested States Detected      =
    =============================================
    Please check the following state(s)
    	Others (Others)
    ---------------------------------------------
    Transition Report
    ---------------------------------------------
    // <<Format>>
    //     (from_state ->to_state): transition_count
    	(DECODE ->DECODE): 15
    	(DECODE ->EXEC): 10
    	(DONE ->IDLE): 3
    	(EXEC ->DONE): 3
    	(EXEC ->FETCH): 7
    	(FETCH ->DECODE): 11
    	(IDLE ->FETCH): 4
    	(IDLE ->IDLE): 7
    	(Others ->IDLE): 0
    
    =============================================
    = Warning !!! Untested Transition Detected  =
    =============================================
    Please check the following transition(s)
      Others (Others) ->IDLE (3'b000)
    ---------------------------------------------
    """#
    static let verdiLp = #"""
    Finite State Machine (lp) Report
    ---------------------------------------------
    Input Signals:
    	a:Control
    	b:Control
    	clk:Clock
    	rst:Control
    
    Output Signals:
    	st[1:0]:Output
    	y:Output
    
    Clock Signal:clk
    Clock Polarity:Rising
    Reset Condition1:rst
    State Signal:st[1:0]
    Initial State:S_A
    State Table:
    	S_A=2'b00
    	S_B=2'b01
    	S_C=2'b10
    	Others=Others
    =============================================
    = Detail State Report                       =
    =============================================
    Others	StateType:
        Transitions:
    	 ->S_A	
    
        State Outputs:
    
    ---------------------------------------------
    S_C	StateType:
        Transitions:
    	 ->S_A	
    
        State Outputs:
        #y=st==S_C;
    ---------------------------------------------
    S_B	StateType:
        Transitions:
    	 ->S_C	b
    
    	 ->S_A	!b
    
        State Outputs:
    
    ---------------------------------------------
    S_A	StateType:
        Transitions:
    	 ->S_B	a
    
    	 ->S_A	!a
    
        State Outputs:
    
    ---------------------------------------------
    State Report
    ---------------------------------------------
    // <<Format>>
    //     state_name: state_count
    	(Trap State): 1
    	Others: 0
    	S_A: 34
    	S_B: 17
    	S_C: 10
    
    =============================================
    = Warning !!! Untested States Detected      =
    =============================================
    Please check the following state(s)
    	Others (Others)
    ---------------------------------------------
    Transition Report
    ---------------------------------------------
    // <<Format>>
    //     (from_state ->to_state): transition_count
    	(Others ->S_A): 0
    	(S_A ->S_A): 17
    	(S_A ->S_B): 17
    	(S_B ->S_A): 6
    	(S_B ->S_C): 10
    	(S_C ->S_A): 10
    
    =============================================
    = Warning !!! Untested Transition Detected  =
    =============================================
    Please check the following transition(s)
      Others (Others) ->S_A (2'b00)
    ---------------------------------------------
    """#
    static let yosysCtl = #"""
    {"modules":{"ctl":{"cells":{"$fsm$\\state$37":{"type":"$fsm","parameters":{"ARST_POLARITY":"1","CLK_POLARITY":"1","CTRL_IN_WIDTH":"00000000000000000000000000000011","CTRL_OUT_WIDTH":"00000000000000000000000000001000","NAME":"\\state","STATE_BITS":"00000000000000000000000000000011","STATE_NUM":"00000000000000000000000000000101","STATE_NUM_LOG2":"00000000000000000000000000000011","STATE_RST":"00000000000000000000000000000000","STATE_TABLE":"111101001100000","TRANS_NUM":"00000000000000000000000000001101","TRANS_TABLE":"100--100000000001100--000000000001011--100000000101011-1001000100101011-0010011100101010--100000001001010--000110001001001--1000000000110011-0001100000110010-001110100011000--100000010000000-1001000110000000-0000000010000"},"connections":{"ARST":["0"],"CLK":[2],"CTRL_IN":[3,4,5],"CTRL_OUT":[6,14,15,16,17,11,12,13]}}},"netnames":{"$procmux$14_CMP":{"bits":[14],"hide_name":1},"$procmux$19_CMP":{"bits":[15],"hide_name":1},"$procmux$22_CMP":{"bits":[16],"hide_name":1},"$procmux$24_CMP":{"bits":[17],"hide_name":1},"$procmux$35_Y":{"bits":[11,12,13],"hide_name":1},"busy":{"bits":[6],"hide_name":0},"go":{"bits":[4],"hide_name":0},"rst":{"bits":[3],"hide_name":0},"stall":{"bits":[5],"hide_name":0}}}}}
    """#
    static let yosysLp = #"""
    {"modules":{"lp":{"cells":{"$fsm$\\st$13":{"type":"$fsm","parameters":{"ARST_POLARITY":"1","CLK_POLARITY":"1","CTRL_IN_WIDTH":"00000000000000000000000000000011","CTRL_OUT_WIDTH":"00000000000000000000000000000101","NAME":"\\st","STATE_BITS":"00000000000000000000000000000010","STATE_NUM":"00000000000000000000000000000011","STATE_NUM_LOG2":"00000000000000000000000000000010","STATE_RST":"00000000000000000000000000000000","STATE_TABLE":"011000","TRANS_NUM":"00000000000000000000000000001000","TRANS_TABLE":"101--00000101001-01100101000-0000010011--0000001010--0000001001--0000100000-11001100000-00000100"},"connections":{"ARST":["0"],"CLK":[4],"CTRL_IN":[2,3,6],"CTRL_OUT":[5,16,17,14,15]}}},"netnames":{"$procmux$11_Y":{"bits":[14,15],"hide_name":1},"$procmux$4_CMP":{"bits":[16],"hide_name":1},"$procmux$5_CMP":{"bits":[17],"hide_name":1},"a":{"bits":[2],"hide_name":0},"b":{"bits":[3],"hide_name":0},"rst":{"bits":[6],"hide_name":0},"y":{"bits":[5],"hide_name":0}}}}}
    """#
    static let yosysTop = #"""
    {"modules":{"top":{"cells":{"$fsm$\\u_ctl.state$54":{"type":"$fsm","parameters":{"ARST_POLARITY":"1","CLK_POLARITY":"1","CTRL_IN_WIDTH":"00000000000000000000000000000011","CTRL_OUT_WIDTH":"00000000000000000000000000001000","NAME":"\\u_ctl.state","STATE_BITS":"00000000000000000000000000000011","STATE_NUM":"00000000000000000000000000000101","STATE_NUM_LOG2":"00000000000000000000000000000011","STATE_RST":"00000000000000000000000000000000","STATE_TABLE":"111101001100000","TRANS_NUM":"00000000000000000000000000001101","TRANS_TABLE":"100--100000000001100--000000000001011--100000000011011-1001000100011011-0010011100011010--100000001001010--000110001001001--1000000001010011-0001100001010010-001110100101000--100000010000000-1001000110000000-0000000010000"},"connections":{"ARST":["0"],"CLK":[4],"CTRL_IN":[6,7,8],"CTRL_OUT":[9,26,27,28,29,21,22,23]}},"$fsm$\\u_lp.st$49":{"type":"$fsm","parameters":{"ARST_POLARITY":"1","CLK_POLARITY":"1","CTRL_IN_WIDTH":"00000000000000000000000000000011","CTRL_OUT_WIDTH":"00000000000000000000000000000101","NAME":"\\u_lp.st","STATE_BITS":"00000000000000000000000000000010","STATE_NUM":"00000000000000000000000000000011","STATE_NUM_LOG2":"00000000000000000000000000000010","STATE_RST":"00000000000000000000000000000000","STATE_TABLE":"011000","TRANS_NUM":"00000000000000000000000000001000","TRANS_TABLE":"101--00000101001-01100101000-0000010011--0000001010--0000001001--0000100000-11001100000-00000100"},"connections":{"ARST":["0"],"CLK":[4],"CTRL_IN":[2,3,6],"CTRL_OUT":[5,30,31,24,25]}}},"netnames":{"$procmux$11_Y":{"bits":[24,25],"hide_name":1},"$procmux$19_CMP":{"bits":[26],"hide_name":1},"$procmux$26_CMP":{"bits":[27],"hide_name":1},"$procmux$34_CMP":{"bits":[28],"hide_name":1},"$procmux$36_CMP":{"bits":[29],"hide_name":1},"$procmux$47_Y":{"bits":[21,22,23],"hide_name":1},"$procmux$4_CMP":{"bits":[30],"hide_name":1},"$procmux$5_CMP":{"bits":[31],"hide_name":1},"a":{"bits":[2],"hide_name":0},"b":{"bits":[3],"hide_name":0},"busy":{"bits":[9],"hide_name":0},"go":{"bits":[7],"hide_name":0},"rst":{"bits":[6],"hide_name":0},"stall":{"bits":[8],"hide_name":0},"u_ctl.busy":{"bits":[9],"hide_name":0},"u_ctl.go":{"bits":[7],"hide_name":0},"u_ctl.rst":{"bits":[6],"hide_name":0},"u_ctl.stall":{"bits":[8],"hide_name":0},"u_lp.a":{"bits":[2],"hide_name":0},"u_lp.b":{"bits":[3],"hide_name":0},"u_lp.rst":{"bits":[6],"hide_name":0},"u_lp.y":{"bits":[5],"hide_name":0},"y":{"bits":[5],"hide_name":0}}}}}
    """#
}

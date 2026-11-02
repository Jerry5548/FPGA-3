`timescale 1ns/1ps
// Configurable complete RGB24 frame slots and an in-order publication queue.
// Camera loss/short frames
// never publish a slot. A slot is released only after all DDR reads retire.
// AXI uses aligned fixed bursts; FRAME_WORDS and LINE_WORDS must be integral,
// FRAME_WORDS divisible by BURST_WORDS; bursts <=256 B and 4-KiB aligned.
module ddr_frame_store_axi #(
    parameter integer IMAGE_WIDTH=1920,IMAGE_HEIGHT=1080,
    parameter integer ADDR_WIDTH=28,BURST_WORDS=16,SLOT_COUNT=2,
    parameter [ADDR_WIDTH-1:0] SLOT_STRIDE=28'h0800000
)(
    input wire clk,rst_n,
    input wire s_valid,output wire s_ready,input wire [127:0] s_data,
    input wire s_sof,s_eol,s_last,s_bad,input wire [31:0] s_frame_id,
    output wire o_valid,input wire o_ready,output wire [127:0] o_data,
    output wire o_sof,o_last,output wire [31:0] o_frame_id,
    output reg [31:0] published_frames,dropped_frames,invalid_frames,
    output reg [31:0] write_errors,read_errors,replayed_frames,
    output wire [31:0] status,
    output reg [255:0] first_fault,
    output wire [ADDR_WIDTH-1:0] awaddr,output wire [7:0] awlen,
    output wire awvalid,input wire awready,
    output wire [127:0] wdata,output wire wlast,wvalid,input wire wready,
    input wire [1:0] bresp,input wire [3:0] bid,input wire bvalid,output wire bready,
    output wire [ADDR_WIDTH-1:0] araddr,output wire [7:0] arlen,
    output wire arvalid,input wire arready,
    input wire [127:0] rdata,input wire [1:0] rresp,input wire [3:0] rid,
    input wire rlast,rvalid,output wire rready
);
    localparam integer FRAME_WORDS=IMAGE_WIDTH*IMAGE_HEIGHT*3/16;
    localparam integer LINE_WORDS=IMAGE_WIDTH*3/16;
    localparam integer WBITS=(BURST_WORDS>1)?$clog2(BURST_WORDS):1;
    localparam integer SBITS=(SLOT_COUNT>1)?$clog2(SLOT_COUNT):1;
    localparam integer QBITS=$clog2(SLOT_COUNT+1);
    localparam [2:0] W_IDLE=0,W_FILL=1,W_ADDR=2,W_DATA=3,W_RESP=4;
    localparam [1:0] R_IDLE=0,R_ADDR=1,R_DATA=2,R_FAULT=3;
    localparam [1:0] FREE=0,WRITING=1,READY=2,READING=3;
    reg [2:0] ws;
    reg [1:0] rs,slots[0:SLOT_COUNT-1];
    reg [31:0] ids[0:SLOT_COUNT-1];
    reg [SBITS-1:0] wslot,rslot,write_next;
    reg [SBITS-1:0] ready_slots[0:SLOT_COUNT-1];
    reg [SBITS-1:0] queue_head,queue_tail;
    reg [QBITS-1:0] ready_count;
    reg slot_free;
    reg [SBITS-1:0] free_slot;
    integer scan,scan_slot,reset_slot;
    reg [31:0] wcount,rcount;
    reg [15:0] column;
    reg [WBITS-1:0] fill_index,write_index,read_index;
    reg [127:0] burst[0:BURST_WORDS-1];
    reg [ADDR_WIDTH-1:0] write_addr,read_addr;
    reg bad,final_burst;
    // Allocate only FREE memory. Queue order is publication order, independent
    // of slot numbers and rejected/short frames. Never overwrite a reader.
    always @* begin
        slot_free=0;free_slot=0;scan_slot=0;
        for(scan=0;scan<SLOT_COUNT;scan=scan+1) begin
            scan_slot=write_next+scan;
            if(scan_slot>=SLOT_COUNT) scan_slot=scan_slot-SLOT_COUNT;
            if(!slot_free && slots[scan_slot]==FREE) begin
                slot_free=1;free_slot=scan_slot;
            end
        end
    end
    function [SBITS-1:0] next_slot;
        input [SBITS-1:0] current;
        begin next_slot=(current==SLOT_COUNT-1) ? 0 : current+1'b1;end
    endfunction
    wire publish=(ws==W_RESP && bvalid && final_burst && !bad && bresp==0 && bid==0);
    wire dequeue=(rs==R_IDLE && ready_count!=0);
    wire interrupted=(ws==W_FILL && s_valid &&
                     (s_sof || s_frame_id!=ids[wslot]));
    assign s_ready=(ws==W_IDLE) || (ws==W_FILL && !interrupted);
    assign awaddr=write_addr;assign awlen=BURST_WORDS-1;
    assign awvalid=ws==W_ADDR;
    assign wdata=burst[write_index];assign wlast=write_index==BURST_WORDS-1;
    assign wvalid=ws==W_DATA;assign bready=ws==W_RESP;
    assign araddr=read_addr;assign arlen=BURST_WORDS-1;
    assign arvalid=rs==R_ADDR;
    wire read_ok=(rresp==0 && rid==0 && rlast==(read_index==BURST_WORDS-1));
    assign o_valid=rs==R_DATA && rvalid && read_ok;
    assign rready=rs==R_FAULT || (rs==R_DATA && (!read_ok || o_ready));
    assign o_data=rdata;assign o_sof=(rcount==0);
    assign o_last=(rcount==FRAME_WORDS-1);assign o_frame_id=ids[rslot];
    wire [31:0] legacy_status={15'd0,(rs==R_FAULT),3'd0,slots[1],slots[0],3'd0,rs,ws};
    // Preserve legacy low state fields. Multi-slot builds additionally report
    // slot capacity [31:24] and queued READY frames [23:16].
    assign status=legacy_status | (SLOT_COUNT>2 ?
        ((SLOT_COUNT<<24) | (ready_count<<16)) : 32'd0);

    // Passive first-rejected-frame recorder. Does not alter ready, admission,
    // rejection or reset behavior. Frozen until reset, including across disable.
    // Reason bits: 0 SOF interruption, 1 ID change, 2 early LAST, 3 missing LAST,
    // 4 wrong EOL, 5 capture bad flag, 6 AXI B response/ID error; bit31 valid.
    wire diag_start=ws==W_IDLE && s_valid && s_sof && slot_free && rs!=R_FAULT;
    wire diag_beat=ws==W_FILL && s_valid && s_ready;
    wire diag_resp=ws==W_RESP && bvalid;
    wire diag_b_error=(bresp!=0 || bid!=0);
    wire expected_eol=diag_start ? (LINE_WORDS==1) : (column==LINE_WORDS-1);
    wire expected_last=diag_start ? (FRAME_WORDS==1) : (wcount==FRAME_WORDS-1);
    reg [6:0] event_reason;
    always @* begin
        event_reason=0;
        if(diag_start || diag_beat) begin
            event_reason[2]=s_last && !expected_last;
            event_reason[3]=!s_last && expected_last;
            event_reason[4]=s_eol!=expected_eol;
            event_reason[5]=s_bad;
        end else if(interrupted) begin
            event_reason[0]=s_sof;
            event_reason[1]=s_frame_id!=ids[wslot];
        end else if(diag_resp) event_reason[6]=diag_b_error;
    end
    wire reject_now=(diag_start && s_last && FRAME_WORDS!=1) ||
        (ws==W_FILL && (interrupted || (diag_beat && s_last && !expected_last))) ||
        (diag_resp && final_burst && (bad || diag_b_error));
    reg [6:0] frame_reasons;
    reg [15:0] diag_row;
    reg [31:0] first_index,first_position,first_flags,first_seen_id;
    wire [6:0] all_reasons=(diag_start ? 7'd0 : frame_reasons) | event_reason;
    wire use_event=diag_start || frame_reasons==0;
    wire [31:0] event_index=diag_start ? 32'd0 : wcount;
    wire [31:0] event_position=diag_start ? 32'd0 : {diag_row,column};
    // Flags [14:12] write FSM, [11:8] BID, [7:6] BRESP, [5] expected LAST,
    // [4] expected EOL, [3] bad, [2] LAST, [1] EOL, [0] SOF.
    // B fields only apply in W_RESP; input fields only in W_IDLE/W_FILL.
    wire [31:0] event_flags={17'd0,ws,bid,bresp,expected_last,expected_eol,
                            s_bad,s_last,s_eol,s_sof};
    wire [31:0] rejected_words=diag_start ? 32'd1 :
        (diag_beat ? wcount+1'b1 : wcount);
    localparam [31:0] DIAG_FRAME_WORDS=FRAME_WORDS;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            first_fault<=0;frame_reasons<=0;diag_row<=0;
            first_index<=0;first_position<=0;first_flags<=0;first_seen_id<=0;
        end else begin
            if(diag_start) begin
                frame_reasons<=event_reason;diag_row<=LINE_WORDS==1 ? 1 : 0;
                first_index<=0;first_position<=0;first_flags<=event_flags;
                first_seen_id<=s_frame_id;
            end else begin
                if(diag_beat && column==LINE_WORDS-1) diag_row<=diag_row+1'b1;
                if(event_reason!=0) begin
                    frame_reasons<=all_reasons;
                    if(frame_reasons==0) begin
                        first_index<=event_index;first_position<=event_position;
                        first_flags<=event_flags;first_seen_id<=s_frame_id;
                    end
                end
            end
            if(reject_now && !first_fault[31]) begin
                first_fault<={DIAG_FRAME_WORDS,
                    (use_event ? s_frame_id : first_seen_id),
                    (use_event ? event_flags : first_flags),
                    (use_event ? event_position : first_position),
                    (use_event ? event_index : first_index),rejected_words,
                    (diag_start ? s_frame_id : ids[wslot]),
                    1'b1,24'd0,all_reasons};
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            ws<=W_IDLE;rs<=R_IDLE;
            for(reset_slot=0;reset_slot<SLOT_COUNT;reset_slot=reset_slot+1) begin
                slots[reset_slot]<=FREE;ids[reset_slot]<=0;ready_slots[reset_slot]<=0;
            end
            wslot<=0;rslot<=0;write_next<=0;queue_head<=0;queue_tail<=0;ready_count<=0;
            wcount<=0;rcount<=0;column<=0;fill_index<=0;write_index<=0;read_index<=0;
            write_addr<=0;read_addr<=0;bad<=0;final_burst<=0;
            published_frames<=0;dropped_frames<=0;invalid_frames<=0;
            write_errors<=0;read_errors<=0;replayed_frames<=0;
        end else begin
            if(publish) begin
                ready_slots[queue_tail]<=wslot;queue_tail<=next_slot(queue_tail);
            end
            if(dequeue) queue_head<=next_slot(queue_head);
            case({publish,dequeue})
                2'b10: ready_count<=ready_count+1'b1;
                2'b01: ready_count<=ready_count-1'b1;
                default: begin end
            endcase
            case(ws)
            W_IDLE: if(s_valid && s_sof) begin
                if(slot_free && rs!=R_FAULT) begin
                    wslot<=free_slot;slots[free_slot]<=WRITING;ids[free_slot]<=s_frame_id;
                    write_next<=next_slot(free_slot);
                    burst[0]<=s_data;wcount<=1;column<=LINE_WORDS==1?0:1;
                    bad<=s_bad || (s_eol!=(LINE_WORDS==1)) || (s_last!=(FRAME_WORDS==1));
                    write_addr<=free_slot*SLOT_STRIDE;write_index<=0;fill_index<=1;
                    final_burst<=FRAME_WORDS==1;
                    if(s_last && FRAME_WORDS!=1) begin
                        slots[free_slot]<=FREE;invalid_frames<=invalid_frames+1'b1;
                    end else if(BURST_WORDS==1) ws<=W_ADDR;
                    else ws<=W_FILL;
                end else dropped_frames<=dropped_frames+1'b1;
            end
            W_FILL: begin
                if(interrupted) begin
                    // Leave the new SOF in the input FIFO for the IDLE state.
                    slots[wslot]<=FREE;ws<=W_IDLE;
                    invalid_frames<=invalid_frames+1'b1;
                end else if(s_valid && s_ready) begin
                    burst[fill_index]<=s_data;wcount<=wcount+1'b1;
                    column<=column==LINE_WORDS-1?0:column+1'b1;
                    bad<=bad || s_bad || (s_eol!=(column==LINE_WORDS-1)) ||
                         (s_last!=(wcount==FRAME_WORDS-1));
                    if(s_last && wcount!=FRAME_WORDS-1) begin
                        slots[wslot]<=FREE;ws<=W_IDLE;
                        invalid_frames<=invalid_frames+1'b1;
                    end else if(fill_index==BURST_WORDS-1) begin
                        final_burst<=wcount==FRAME_WORDS-1;write_index<=0;ws<=W_ADDR;
                    end else fill_index<=fill_index+1'b1;
                end
            end
            W_ADDR: if(awready) begin write_index<=0;ws<=W_DATA;end
            W_DATA: if(wready) begin
                if(write_index==BURST_WORDS-1) ws<=W_RESP;
                else write_index<=write_index+1'b1;
            end
            W_RESP: if(bvalid) begin
                if(bresp!=0 || bid!=0) begin bad<=1;write_errors<=write_errors+1'b1;end
                if(final_burst) begin
                    ws<=W_IDLE;
                    if(bad || bresp!=0 || bid!=0) begin
                        slots[wslot]<=FREE;invalid_frames<=invalid_frames+1'b1;
                    end else begin slots[wslot]<=READY;published_frames<=published_frames+1'b1;end
                end else begin
                    write_addr<=write_addr+BURST_WORDS*16;fill_index<=0;ws<=W_FILL;
                end
            end
            endcase

            case(rs)
            R_IDLE: if(dequeue) begin
                rslot<=ready_slots[queue_head];slots[ready_slots[queue_head]]<=READING;
                read_addr<=ready_slots[queue_head]*SLOT_STRIDE;
                rcount<=0;read_index<=0;rs<=R_ADDR;
            end
            R_ADDR: if(arready) begin read_index<=0;rs<=R_DATA;end
            R_DATA: if(rvalid && rready) begin
                if(!read_ok) begin
                    // Partial output cannot be retracted. Never send its
                    // frame LAST or a new frame after a bus/protocol error.
                    read_errors<=read_errors+1'b1;rs<=R_FAULT;
                end else begin
                    rcount<=rcount+1'b1;
                    if(read_index==BURST_WORDS-1) begin
                        if(rcount==FRAME_WORDS-1) begin
                            slots[rslot]<=FREE;replayed_frames<=replayed_frames+1'b1;rs<=R_IDLE;
                        end else begin
                            read_addr<=read_addr+BURST_WORDS*16;read_index<=0;rs<=R_ADDR;
                        end
                    end else read_index<=read_index+1'b1;
                end
            end
            endcase
        end
    end
endmodule

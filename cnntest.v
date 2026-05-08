//==============================================================================
// FILE: cnntest.v
// DESCRIPTION: paper of cicai
// 
//==============================================================================

module cnntest #(
    parameter IMG_WIDTH_MAX = 1920 
)(
    // --- Global Signals ---
    input  wire        clk,
    input  wire        rst_n,

    // --- Video Input Stream ---
    input  wire        i_href,      
    input  wire        i_valid,    
    input  wire [7:0]  i_pixel,
    input  wire        i_vsync,    

    // --- Feature Map Output Stream ---
    output reg         o_valid,
    output reg  [7:0]  o_feature,
    output reg         o_vsync
);

//==============================================================================
// 1. Configuration
//==============================================================================
reg [7:0]  cfg_ctrl;
reg [7:0]  cfg_act_mode;
reg [7:0]  cfg_act_param;
reg [7:0]  cfg_pool_mode; 

reg [71:0] cfg_kernel_a;
reg [71:0] cfg_kernel_b;
reg        cfg_kernel_select; 

wire ip_en       = cfg_ctrl[0];
wire soft_reset  = cfg_ctrl[1];
wire auto_swap   = cfg_ctrl[4];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cfg_ctrl          <= 8'h01; 
        cfg_act_mode      <= 2'h0; 
        cfg_act_param     <= 8'h0; 
        cfg_pool_mode     <= 2'h0; 
        cfg_kernel_a      <= 72'hFFFFFFFF08FFFFFFFF; 
        cfg_kernel_b      <= 72'h0;
        cfg_kernel_select <= 1'b0;
    end else begin
        if (auto_swap && i_vsync) begin
             cfg_kernel_select <= ~cfg_kernel_select;
        end
    end
end

//==============================================================================
// 2. 
//==============================================================================
reg [11:0] r_width_cnt;
reg [11:0] r_height_cnt;
reg [11:0] dynamic_width;
reg [11:0] dynamic_height;

reg r_href_d1;
reg r_vsync_d1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r_href_d1        <= 1'b0;
        r_vsync_d1       <= 1'b0;
        r_width_cnt      <= 12'd0;
        r_height_cnt     <= 12'd0;
        dynamic_width    <= 12'd1920; 
        dynamic_height   <= 12'd1080;
    end else begin
        r_href_d1  <= i_href;
        r_vsync_d1 <= i_vsync;

        // --- 
        if (i_href) begin
            r_width_cnt <= r_width_cnt + 1'b1;
        end else if (r_href_d1 && !i_href) begin 
            dynamic_width <= r_width_cnt;
            r_width_cnt   <= 12'd0;
            
            if (!i_vsync) begin
                r_height_cnt <= r_height_cnt + 1'b1;
            end
        end

        // --- -
        if (!r_vsync_d1 && i_vsync) begin 
            dynamic_height   <= r_height_cnt;
            r_height_cnt     <= 12'd0;
        end
    end
end

//==============================================================================
// 3. STAGE 1: 
//==============================================================================
(* ramstyle = "M9K" *) reg [7:0] line_buffer1 [0:IMG_WIDTH_MAX-1];
(* ramstyle = "M9K" *) reg [7:0] line_buffer2 [0:IMG_WIDTH_MAX-1];

reg [11:0] x_coord; 
reg [11:0] y_coord; 
reg [7:0]  win_reg [0:8]; 

reg [11:0] x_coord_d1;
reg        i_valid_d1;

always @(posedge clk) begin
    if (!rst_n || soft_reset) begin
        x_coord    <= 0;
        y_coord    <= 0;
        x_coord_d1 <= 0;
        i_valid_d1 <= 0;
    end else begin
        x_coord_d1 <= x_coord;
        i_valid_d1 <= i_valid && ip_en; 

        if (i_vsync) begin
            x_coord <= 0;
            y_coord <= 0;
        end else if (r_href_d1 && !i_href) begin
            x_coord <= 0;
            y_coord <= y_coord + 1;
        end else if (i_valid && ip_en) begin
            x_coord <= x_coord + 1;
        end
    end
end

always @(posedge clk) begin
    if (i_valid && ip_en) begin
        win_reg[2] <= i_pixel;
        win_reg[1] <= win_reg[2];
        win_reg[0] <= win_reg[1];
        
        win_reg[5] <= line_buffer1[x_coord];
        win_reg[4] <= win_reg[5];
        win_reg[3] <= win_reg[4];
        
        win_reg[8] <= line_buffer2[x_coord];
        win_reg[7] <= win_reg[8];
        win_reg[6] <= win_reg[7];
        
        line_buffer1[x_coord] <= i_pixel;
    end
end

always @(posedge clk) begin
    if (i_valid_d1) begin
        line_buffer2[x_coord_d1] <= win_reg[5];
    end
end

reg s1_valid; 
always @(posedge clk) begin
    s1_valid <= (y_coord >= 2) && (x_coord >= 2) && i_valid && ip_en;
end

//==============================================================================
// 4. STAGE 2:
//==============================================================================
wire [71:0] active_kernel = cfg_kernel_select ? cfg_kernel_b : cfg_kernel_a;
wire [7:0]  kernel_w [0:8];
wire [12:0] mul_results [0:8];

reg signed [12:0] s2_conv_sum; 
reg               s2_valid;

genvar j;
generate
for (j=0; j<9; j=j+1) begin: kernel_unpacker
    assign kernel_w[j] = active_kernel[8*(j+1)-1 -: 8];
end
endgenerate

generate
    genvar i;
    for (i = 0; i < 9; i = i + 1) begin : mul_gen
        wire [7:0] abs_weight = (kernel_w[i][7]) ? -kernel_w[i] : kernel_w[i];
        wire [15:0] abs_prod;

        auc_multiply_8bit auc_inst (
            .a(win_reg[i]),      
            .b(abs_weight),      
            .res(abs_prod)       
        );
        assign mul_results[i] = (kernel_w[i][7]) ? -abs_prod[12:0] : abs_prod[12:0];
    end
endgenerate

always @(posedge clk) begin
    s2_valid <= s1_valid;
    if (s1_valid) begin
        s2_conv_sum <= $signed(mul_results[0]) + $signed(mul_results[1]) + $signed(mul_results[2]) +
                       $signed(mul_results[3]) + $signed(mul_results[4]) + $signed(mul_results[5]) +
                       $signed(mul_results[6]) + $signed(mul_results[7]) + $signed(mul_results[8]);
    end
end

//==============================================================================
// 5. STAGE 3: 
//==============================================================================
reg [2:0] vsync_delay; 
always @(posedge clk) begin
    if (!rst_n) vsync_delay <= 0;
    else vsync_delay <= {vsync_delay[1:0], i_vsync};
end


wire [12:0] relu_val = (s2_conv_sum < 0) ? 13'd0 : s2_conv_sum;

//==============================================================================
// 6. STAGE 4:
//==============================================================================
always @(posedge clk) begin
    o_valid <= 0;
    o_vsync <= vsync_delay[2];

    if (s2_valid && ip_en) begin
        o_feature <= (relu_val > 255) ? 8'hFF : relu_val[7:0];
        o_valid   <= 1;
    end
end

endmodule

//==============================================================================
// SUB-MODULE: 
//==============================================================================
module auc_multiply_8bit(
    input  [7:0] a,
    input  [7:0] b,
    output [15:0] res 
);

    wire [3:0] a_h = a[7:4];
    wire [3:0] a_l = a[3:0];
    wire [3:0] b_h = b[7:4];
    wire [3:0] b_l = b[3:0];
    
    wire [7:0] p_hh; // Weight 256
    wire [7:0] p_hl; // Weight 16
    wire [7:0] p_lh; // Weight 16
    wire [7:0] p_ll; // Weight 1

    auc_lut_4x4 u_hh (.a(a_h), .b(b_h), .p(p_hh));
    auc_lut_4x4 u_hl (.a(a_h), .b(b_l), .p(p_hl));
    auc_lut_4x4 u_lh (.a(a_l), .b(b_h), .p(p_lh));
    auc_lut_4x4 u_ll (.a(a_l), .b(b_l), .p(p_ll));

    wire [8:0] mid_sum = p_hl + p_lh; 
    
    assign res = {p_hh, 8'b0} + {mid_sum, 4'b0} + p_ll;

endmodule

//==============================================================================
// SUB-MODULE
//==============================================================================
module auc_lut_4x4(
    input  [3:0] a,
    input  [3:0] b,
    output reg [7:0] p
);
    always @(*) begin
        p = a * b; 
    end
endmodule
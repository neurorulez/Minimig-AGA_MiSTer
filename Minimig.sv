/********************************************/
/* minimig.sv                               */
/* MiSTer glue logic                        */
/* 2017-2019 Alexey Melnikov                */
/********************************************/


module emu
(
	//Master input clock
	input         CLK_50M,
	
	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,
	
	//Must be passed to hps_io module
	inout  [45:0] HPS_BUS,
	
	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,
	
	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,
	
	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	output  [7:0] VIDEO_ARX,
	output  [7:0] VIDEO_ARY,
	
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output  [1:0] VGA_SL,
	
	output        LED_USER,  // 1 - ON, 0 - OFF.
	
	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,
	
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S, // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)
	
	//ADC
	inout   [3:0] ADC_BUS,
	
	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,
	
	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,
	
	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,
	
	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,
	
	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign BUTTONS = 0;


`include "build_id.v" 
localparam CONF_STR = {
	"Minimig;;",
	"V,v",`BUILD_DATE
};

wire [15:0] JOY0;
wire [15:0] JOY1;
wire [15:0] JOY2;
wire [15:0] JOY3;
wire  [7:0] KBD_MOUSE_DATA;
wire        KMS_LEVEL;
wire  [1:0] KBD_MOUSE_TYPE;
wire  [2:0] MOUSE_BUTTONS;
wire [63:0] RTC;

wire [15:0] uio_dout;
wire [15:0] fpga_dout;
wire        ce_pix;
wire [15:0] sdram_sz;
wire  [1:0] buttons;

wire        io_strobe;
wire        io_wait;
wire        io_fpga;
wire        io_uio;
wire [15:0] io_din;

hps_io_minimig #(.STRLEN($size(CONF_STR)>>3)) hps_io
(
	.*,
	.conf_str(CONF_STR),

	.IO_STROBE(io_strobe),
	.IO_DIN(io_din),
	.UIO_ENA(io_uio),
	.FPGA_ENA(io_fpga),
	.FPGA_DOUT(fpga_dout),
	.FPGA_WAIT(io_wait),
	
	.BUTTONS(buttons),
	.new_vmode()
);


assign SDRAM_CKE    = 1;

assign AUDIO_L      = {ldata, 1'b0};
assign AUDIO_R      = {rdata, 1'b0};
assign AUDIO_S      = 1;

assign LED_POWER[1] = 1;
assign LED_DISK[1]  = 1;

assign VGA_HS       = ~hs;
assign VGA_VS       = ~vs;
assign VIDEO_ARX    = ar[0] ? 8'd16 : 8'd4;
assign VIDEO_ARY    = ar[0] ? 8'd9  : 8'd3;
assign CE_PIXEL     = ce_out;

reg ce_out = 0;
always @(posedge CLK_VIDEO) ce_out <= ~ce_out;

wire clk_mem;
wire clk_sys;
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.outclk_0(clk_mem),
	.outclk_1(SDRAM_CLK),
	.outclk_2(clk_sys),
	.outclk_3(CLK_VIDEO),
	.locked(pll_locked),

	.phase_en(phase_en),
	.scanclk(clk_sys),
	.updn(updn),
	.cntsel(1),
	.phase_done(phase_done)
);

wire phase_en, updn, phase_done;
phase_shift #(.M64MB(-5), .M128MB(-8)) phase_shift
(
	.clk(clk_sys),
	.pll_locked(pll_locked),

	.phase_en(phase_en),
	.updn(updn),
	.phase_done(phase_done),

	.sdram_sz(sdram_sz)
);

//// amiga clocks ////
wire        clk7_en;
wire        clk7n_en;
wire        c1;
wire        c3;
wire        cck;
wire  [9:0] eclk;

amiga_clk amiga_clk
(
	.clk_28       (clk_sys          ), // input  clock c1 ( 28.687500MHz)
	.clk7_en      (clk7_en          ), // output clock 7 enable (on 28MHz clock domain)
	.clk7n_en     (clk7n_en         ), // 7MHz negedge output clock enable (on 28MHz clock domain)
	.c1           (c1               ), // clk28m clock domain signal synchronous with clk signal
	.c3           (c3               ), // clk28m clock domain signal synchronous with clk signal delayed by 90 degrees
	.cck          (cck              ), // colour clock output (3.54 MHz)
	.eclk         (eclk             ), // 0.709379 MHz clock enable output (clk domain pulse)
	.locked       (pll_locked       )  // pll locked output
);

wire        cache_inhibit;
wire [31:0] tg68_cad;
wire  [1:0] tg68_cpustate;
wire        tg68_ramcs;
wire        tg68_nrst_out;
wire        tg68_clds;
wire        tg68_cuds;
wire  [3:0] tg68_CACR_out;
wire [31:0] tg68_VBR_out;
wire        tg68_rst;
wire [15:0] tg68_dat_in;
wire [15:0] tg68_dat_out;
wire [31:0] tg68_adr;
wire  [2:0] tg68_IPL;
wire        tg68_dtack;
wire        tg68_as;
wire        tg68_uds;
wire        tg68_lds;
wire        tg68_rw;
wire [15:0] tg68_cout   = DDR_EN ? tg68_cout2     : tg68_cout1;
wire        tg68_cpuena = DDR_EN ? tg68_ramready2 : tg68_ramready1;

TG68K tg68k
(
	.clk          (clk_mem          ),
	.reset        (tg68_rst         ),
	.ce_7         (clk7_en          ),
	.IPL          (tg68_IPL         ),
	.dtack        (tg68_dtack       ),
	.addr         (tg68_adr         ),
	.data_read    (tg68_dat_in      ),
	.data_write   (tg68_dat_out     ),
	.as           (tg68_as          ),
	.uds          (tg68_uds         ),
	.lds          (tg68_lds         ),
	.rw           (tg68_rw          ),
	.fromram      (tg68_cout        ),
	.ramready     (tg68_cpuena      ),
	.cpu          (cpu_config[1:0]  ),
	.turbochipram (turbochipram     ),
	.turbokick    (turbokick        ),
	.cache_inhibit(cache_inhibit    ),
	.fastramcfg   (memcfg[6:4]      ),
	.bootrom      (bootrom          ),
	.ramaddr      (tg68_cad         ),
	.ramcs        (tg68_ramcs       ),
	.nResetOut    (tg68_nrst_out    ),
	.ramlds       (tg68_clds        ),
	.ramuds       (tg68_cuds        ),
 
	//custom CPU signals
	.cpustate     (tg68_cpustate    ),
	.CACR_out     (tg68_CACR_out    ),
	.VBR_out      (tg68_VBR_out     )
);

wire DDR_EN = tg68_cad[29];
wire SDR_EN = ~tg68_cad[29];

wire [15:0] tg68_cout1;
wire        tg68_ramready1;
sdram_ctrl ram1
(
	.sysclk       (clk_mem          ),
	.reset_in     (pll_locked       ),
	.c_7m         (c1               ),

	.cache_rst    (tg68_rst         ),
	.cache_inhibit(cache_inhibit    ),
	.cpu_cache_ctrl(tg68_CACR_out   ),

	.sdata        (SDRAM_DQ         ),
	.sdaddr       (SDRAM_A          ),
	.dqm          ({SDRAM_DQMH, SDRAM_DQML}),
	.sd_cs        (SDRAM_nCS        ),
	.ba           (SDRAM_BA         ),
	.sd_we        (SDRAM_nWE        ),
	.sd_ras       (SDRAM_nRAS       ),
	.sd_cas       (SDRAM_nCAS       ),

	.cpuWR        (tg68_dat_out     ),
	.cpuAddr      (tg68_cad[22:1]   ),
	.cpuU         (tg68_cuds        ),
	.cpuL         (tg68_clds        ),
	.cpustate     (tg68_cpustate    ),
	.cpuCS        (SDR_EN & tg68_ramcs ),
	.cpuRD        (tg68_cout1       ),
	.ramready     (tg68_ramready1   ),

	.chipWR       (ram_data         ),
	.chipAddr     (ram_address      ),
	.chipU        (_ram_bhe         ),
	.chipL        (_ram_ble         ),
	.chipRW       (_ram_we          ),
	.chip_dma     (_ram_oe          ),
	.chipRD       (ramdata_in       ),
	.chip48       (chip48           )
);

wire [15:0] tg68_cout2;
wire        tg68_ramready2;
ddram_ctrl ram2
(
	.sysclk       (clk_mem          ),
	.reset_in     (pll_locked       ),

	.cache_rst    (tg68_rst         ),
	.cache_inhibit(cache_inhibit    ),
	.cpu_cache_ctrl(tg68_CACR_out   ),

	.DDRAM_CLK    (DDRAM_CLK        ),
	.DDRAM_BUSY   (DDRAM_BUSY       ),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT  ),
	.DDRAM_ADDR   (DDRAM_ADDR       ),
	.DDRAM_DOUT   (DDRAM_DOUT       ),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD     (DDRAM_RD         ),
	.DDRAM_DIN    (DDRAM_DIN        ),
	.DDRAM_BE     (DDRAM_BE         ),
	.DDRAM_WE     (DDRAM_WE         ),

	.cpuWR        (tg68_dat_out     ),
	.cpuAddr      (tg68_cad[28:1]   ),
	.cpuU         (tg68_cuds        ),
	.cpuL         (tg68_clds        ),
	.cpustate     (tg68_cpustate    ),
	.cpuCS        (DDR_EN & tg68_ramcs ),
	.cpuRD        (tg68_cout2       ),
	.ramready     (tg68_ramready2   )
);


//// minimig top ////
wire  [3:0] cpu_config;
wire  [6:0] memcfg;
wire        turbochipram;
wire        turbokick;
wire        bootrom;   
wire [15:0] ram_data;      // sram data bus
wire [15:0] ramdata_in;    // sram data bus in
wire [47:0] chip48;        // big chip read
wire [23:1] ram_address;   // sram address bus
wire        _ram_bhe;      // sram upper byte select
wire        _ram_ble;      // sram lower byte select
wire        _ram_we;       // sram write enable
wire        _ram_oe;       // sram output enable
wire [14:0] ldata;         // left DAC data
wire [14:0] rdata;         // right DAC data
wire        vs;
wire        hs;
wire  [1:0] ar;

minimig minimig
(
	//m68k pins
	.cpu_address  (tg68_adr[23:1]   ), // M68K address bus
	.cpu_data     (tg68_dat_in      ), // M68K data bus
	.cpudata_in   (tg68_dat_out     ), // M68K data in
	._cpu_ipl     (tg68_IPL         ), // M68K interrupt request
	._cpu_as      (tg68_as          ), // M68K address strobe
	._cpu_uds     (tg68_uds         ), // M68K upper data strobe
	._cpu_lds     (tg68_lds         ), // M68K lower data strobe
	.cpu_r_w      (tg68_rw          ), // M68K read / write
	._cpu_dtack   (tg68_dtack       ), // M68K data acknowledge
	._cpu_reset   (tg68_rst         ), // M68K reset
	._cpu_reset_in(tg68_nrst_out    ), // M68K reset out
	.cpu_vbr      (tg68_VBR_out     ), // M68K VBR

	//sram pins
	.ram_data     (ram_data         ), // SRAM data bus
	.ramdata_in   (ramdata_in       ), // SRAM data bus in
	.ram_address  (ram_address[23:1]), // SRAM address bus
	._ram_bhe     (_ram_bhe         ), // SRAM upper byte select
	._ram_ble     (_ram_ble         ), // SRAM lower byte select
	._ram_we      (_ram_we          ), // SRAM write enable
	._ram_oe      (_ram_oe          ), // SRAM output enable
	.chip48       (chip48           ), // big chipram read

	//system  pins
	.rst_ext      (buttons[1]       ), // reset from ctrl block
	.rst_out      (                 ), // minimig reset status
	.clk          (clk_sys          ), // output clock c1 ( 28.687500MHz)
	.clk7_en      (clk7_en          ), // 7MHz clock enable
	.clk7n_en     (clk7n_en         ), // 7MHz negedge clock enable
	.c1           (c1               ), // clk28m clock domain signal synchronous with clk signal
	.c3           (c3               ), // clk28m clock domain signal synchronous with clk signal delayed by 90 degrees
	.cck          (cck              ), // colour clock output (3.54 MHz)
	.eclk         (eclk             ), // 0.709379 MHz clock enable output (clk domain pulse)

	//rs232 pins
	.rxd          (UART_RXD         ), // RS232 receive
	.txd          (UART_TXD         ), // RS232 send
	.cts          (UART_CTS         ), // RS232 clear to send
	.rts          (UART_RTS         ), // RS232 request to send
	.dtr          (UART_DTR         ), // RS232 Data Terminal Ready
	.dsr          (UART_DSR         ), // RS232 Data Set Ready
	.cd           (UART_DSR         ), // RS232 Carrier Detect
	.ri           (1                ), // RS232 Ring Indicator

	//I/O
	._joy1        (~JOY0            ), // joystick 1 [fire4,fire3,fire2,fire,up,down,left,right] (default mouse port)
	._joy2        (~JOY1            ), // joystick 2 [fire4,fire3,fire2,fire,up,down,left,right] (default joystick port)
	._joy3        (~JOY2            ), // joystick 1 [fire4,fire3,fire2,fire,up,down,left,right]
	._joy4        (~JOY3            ), // joystick 2 [fire4,fire3,fire2,fire,up,down,left,right]
	.mouse_btn    (MOUSE_BUTTONS    ), // mouse buttons
	.kbd_mouse_data (KBD_MOUSE_DATA ), // mouse direction data, keycodes
	.kbd_mouse_type (KBD_MOUSE_TYPE ), // type of data
	.kms_level    (KMS_LEVEL        ),
	.pwr_led      (LED_POWER[0]     ), // power led
	.fdd_led      (LED_USER         ),
	.hdd_led      (LED_DISK[0]      ),
	.rtc          (RTC              ),

	//host controller interface (SPI)
	.IO_UIO       (io_uio           ),
	.IO_FPGA      (io_fpga          ),
	.IO_STROBE    (io_strobe        ),
	.IO_WAIT      (io_wait          ),
	.IO_DIN       (io_din           ),
	.IO_DOUT      (fpga_dout        ),

	//video
	._hsync       (hs               ), // horizontal sync
	._vsync       (vs               ), // vertical sync
	.field1       (VGA_F1           ),
	.red          (VGA_R            ), // red
	.green        (VGA_G            ), // green
	.blue         (VGA_B            ), // blue
	.hblank       (hblank           ),
	.vblank       (vbl              ),
	.ar           (ar               ),
	.scanline     (VGA_SL           ),
	.ce_pix       (ce_pix           ),
	.res          (res              ),

	//audio
	.ldata        (ldata            ), // left DAC data
	.rdata        (rdata            ), // right DAC data
	.aud_mix      (AUDIO_MIX        ),

	//user i/o
	.cpu_config   (cpu_config       ), // CPU config
	.memcfg       (memcfg           ), // memory config
	.turbochipram (turbochipram     ), // turbo chipRAM
	.turbokick    (turbokick        ), // turbo kickstart
	.bootrom      (bootrom          ), // bootrom mode. Needed here to tell tg68k to also mirror the 256k Kickstart 

	.trackdisp    (                 ), // floppy track number
	.secdisp      (                 ), // sector
	.floppy_fwr   (                 ), // floppy fifo writing
	.floppy_frd   (                 ), // floppy fifo reading
	.hd_fwr       (                 ), // hd fifo writing
	.hd_frd       (                 )  // hd fifo reading
);

assign VGA_DE = hde & vde;

reg  hde;
wire vde = ~(fvbl | svbl);

wire [7:0] red, green, blue, r,g,b;
wire hblank, vbl;
wire vblank = vbl | ~vs;
reg  fhbl, fvbl, shbl, svbl;
wire hbl = fhbl | shbl | ~hs;

wire  [1:0] res;

wire sset;
wire [11:0] shbl_l, shbl_r;
wire [11:0] svbl_t, svbl_b;

reg  [11:0] hbl_l=0, hbl_r=0;
reg  [11:0] hsta, hend, hmax, hcnt;
reg  [11:0] hsize;
always @(posedge clk_sys) begin
	reg old_hs;
	reg old_hblank;

	old_hs <= hs;
	old_hblank <= hblank;

	hcnt <= hcnt + 1'd1;
	if(~hs) hcnt <= 0;

	if(old_hblank & ~hblank) hend <= hcnt;
	if(~old_hblank & hblank) hsta <= hcnt;
	if(old_hs & ~hs)         hmax <= hcnt;

	if(hcnt == hend+hbl_l-2'd2) shbl <= 0;
	if(hcnt == hsta+hbl_r-2'd2) shbl <= 1;

	//force hblank
	if(hcnt == 8)         fhbl <= 0;
	if(hcnt == hmax-4'd8) fhbl <= 1;
	
	if(~old_hblank & hblank & ~VGA_F1 & (vcnt == vsta+1'd1)) hsize <= hcnt - hend;
end

reg [11:0] vbl_t=0, vbl_b=0;
reg [11:0] vsta, vend, vmax, f1_vend, f1_vsize, vcnt;
reg [11:0] vsize;
always @(posedge clk_sys) begin
	reg old_vs;
	reg old_vblank, old_hs, old_hbl;

	old_vs <= vs;
	old_hs <= hs;
	old_vblank <= vblank;
	
	if(old_hs & ~hs) vcnt <= vcnt + 1'd1;
	if(~vs) vcnt <= 0;

	if(~VGA_F1) begin
		if(old_vblank & ~vblank) vend <= vcnt;
		if(~old_vblank & vblank) vsta <= vcnt;
		if(old_vs & ~vs)         vmax <= vcnt;
		
		if(~old_vblank & vblank) begin
			vsize <= vcnt - vend + f1_vsize;
			f1_vsize <= 0;
		end
	end
	else begin
		if(old_vblank & ~vblank) f1_vend <= vcnt;
		if(~old_vblank & vblank) begin
			f1_vsize <= vcnt - f1_vend;
		end
	end

	old_hbl <= hbl;
	if(old_hbl & ~hbl) begin
		if(vcnt == vend+vbl_t-1'd1) svbl <= 0;
		if(vcnt == vsta+vbl_b-1'd1) svbl <= 1;

		//force vblank
		if(vcnt == 1)         fvbl <= 0;
		if(vcnt == vmax-4'd3) fvbl <= 1;
	end
	
	hde <= ~hbl;
end

always @(posedge clk_sys) begin
	reg old_level;
	reg alt = 0;

	old_level <= KMS_LEVEL;
	if((old_level ^ KMS_LEVEL) && (KBD_MOUSE_TYPE==3)) begin
		if(KBD_MOUSE_DATA == 'h41) begin //backspace
			vbl_t <= 0; vbl_b <= 0;
			hbl_l <= 0; hbl_r <= 0;
		end
		else if(KBD_MOUSE_DATA == 'h4c) begin //up
			if(alt) vbl_b <= vbl_b + 1'd1;
			else    vbl_t <= vbl_t + 1'd1;
		end
		else if(KBD_MOUSE_DATA == 'h4d) begin //down
			if(alt) vbl_b <= vbl_b - 1'd1;
			else    vbl_t <= vbl_t - 1'd1;
		end
		else if(KBD_MOUSE_DATA == 'h4f) begin //left
			if(alt) hbl_r <= hbl_r + 3'd4;
			else    hbl_l <= hbl_l + 3'd4;
		end
		else if(KBD_MOUSE_DATA == 'h4e) begin //right
			if(alt) hbl_r <= hbl_r - 3'd4;
			else    hbl_l <= hbl_l - 3'd4;
		end
		else if(KBD_MOUSE_DATA == 'h64 || KBD_MOUSE_DATA == 'h65) begin //alt press
			alt <= 1;
		end
		else if(KBD_MOUSE_DATA == 'hE4 || KBD_MOUSE_DATA == 'hE5) begin //alt release
			alt <= 0;
		end
	end
	
	if(sset) begin
		vbl_t <= svbl_t; vbl_b <= svbl_b;
		hbl_l <= shbl_l; hbl_r <= shbl_r;
	end
end


reg [11:0] scr_hbl_l, scr_hbl_r;
reg [11:0] scr_vbl_t, scr_vbl_b;
reg [11:0] scr_hsize, scr_vsize;
reg  [1:0] scr_res;
reg  [6:0] scr_flg;

always @(posedge clk_sys) begin
	reg old_vblank;

	old_vblank <= vblank;
	if(old_vblank & ~vblank) begin
		scr_hbl_l <= hbl_l;
		scr_hbl_r <= hbl_r;
		scr_vbl_t <= vbl_t;
		scr_vbl_b <= vbl_b;
		scr_hsize <= hsize;
		scr_vsize <= vsize;
		scr_res   <= res;

		if(scr_res != res || scr_vsize != vsize || scr_hsize != hsize) scr_flg <= scr_flg + 1'd1;
	end
end

endmodule

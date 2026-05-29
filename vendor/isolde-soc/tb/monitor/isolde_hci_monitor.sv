// Copyleft 2025 ISOLDE
//

module isolde_hci_monitor #(
    parameter int unsigned DW = hci_package::DEFAULT_DW,  /// Data Width
    parameter int unsigned AW = hci_package::DEFAULT_AW,  /// Address Width
    parameter string       NAME = "isolde_hci_monitor",
    parameter int          ID = 0  // ID of the HCI monitor (default 0)
) (
    input  logic clk_i,
    input  logic rst_ni,

    hci_core_intf.monitor hci_core
);

  typedef enum logic [1:0] {
    idle,
    log_req_r,
    log_req_w,
    log_data
  } hci_mon_state_t;

  hci_mon_state_t hci_mon_state, hci_mon_state_next;

  // request phase payload
  logic [AW-1:0] add;
  logic [DW-1:0] data;
  logic          wen;

  int    fh_csv;       // filehandle
  string log_filename;

  //--------------------------------------------------------------------------
  // Next-state logic
  //--------------------------------------------------------------------------
  always_comb begin
    hci_mon_state_next = hci_mon_state; // default hold

    case (hci_mon_state)
      idle: begin
        if (hci_core.req) begin
          if (hci_core.wen) hci_mon_state_next = log_req_r;
          else              hci_mon_state_next = hci_core.be ? log_req_w : idle;
        end
      end

      log_req_r,
      log_req_w: begin
        hci_mon_state_next = log_data;
      end

      log_data: begin
        if (hci_core.r_valid) hci_mon_state_next = idle;
      end

      default: hci_mon_state_next = idle;
    endcase
  end

  //--------------------------------------------------------------------------
  // Sequential logic (single driver for hci_mon_state)
  //--------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hci_mon_state <= idle;
      add           <= '0;
      data          <= '0;
      wen           <= 1'b0;
    end else begin
      hci_mon_state <= hci_mon_state_next;

      case (hci_mon_state_next)
        log_req_r: begin
          add <= hci_core.add;
          wen <= hci_core.wen;
        end

        log_req_w: begin
          add  <= hci_core.add;
          wen  <= hci_core.wen;
          data <= hci_core.data;
        end

        log_data: begin
          if (hci_core.r_valid) begin
            if (~wen) $fwrite(fh_csv, "%t, write, 0x%h, 0x%h\n", $time, add, data);
            else      $fwrite(fh_csv, "%t, read, 0x%h, 0x%h\n",  $time, add, hci_core.r_data);
          end
        end

        default: begin
          // no-op
        end
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // File open / header
  //--------------------------------------------------------------------------
  initial begin
    log_filename = $sformatf("%s_%0d.csv", NAME, ID);
    fh_csv = $fopen(log_filename, "w");
    if (fh_csv == 0) begin
      $display("ERROR: Could not open %s for writing", log_filename);
      $finish;
    end else begin
      $fwrite(fh_csv, "time,op,addr,data\n");
    end
  end

  //--------------------------------------------------------------------------
  // File close
  //--------------------------------------------------------------------------
  final begin
    if (fh_csv != 0) begin
      $fclose(fh_csv);
    end
  end

endmodule

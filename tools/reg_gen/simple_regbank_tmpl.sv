{% if cpuif.addr_width < 8 -%}
assign cpuif_req = (reg_we_i | reg_re_i) & (reg_addr_i[7:{{cpuif.addr_width}}] == '0);
{% else -%}
assign cpuif_req = reg_we_i | reg_re_i;
{% endif -%}
assign cpuif_req_is_wr = reg_we_i;
assign cpuif_addr = reg_addr_i[{{cpuif.addr_width-1}}:0];
assign cpuif_wr_data = reg_wdata_i;
assign cpuif_wr_biten = '1;

always_ff {{get_always_ff_event(cpuif.reset)}} begin
    if({{get_resetsignal(cpuif.reset)}}) begin
        reg_rdata_o <= '0;
    end else if(reg_re_i) begin
        reg_rdata_o <= cpuif_rd_data;
    end
end


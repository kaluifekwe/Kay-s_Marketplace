import { useState } from "react";
import { List, useTable, DateField } from "@refinedev/antd";
import { Table, Tag, Radio, Space, Typography, Button, Popconfirm, Input, Alert, App } from "antd";
import { CheckOutlined, CloseOutlined } from "@ant-design/icons";
import type { CrudFilters } from "@refinedev/core";
import { naira } from "../../format";
import { supabaseClient } from "../../supabaseClient";

const { Text, Paragraph } = Typography;

const SELECT = "*, buyer:users!refund_requests_buyer_id_fkey(name,email)";

const statusColour = (s: string) =>
  s === "pending" ? "orange" : s === "approved" ? "green" : "red";

export const RefundList = () => {
  const { message } = App.useApp();
  const [busy, setBusy] = useState<string | null>(null);
  const [notes, setNotes] = useState<Record<string, string>>({});

  const { tableProps, setFilters, filters, tableQueryResult } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "created_at", order: "desc" }] },
    filters: { initial: [{ field: "status", operator: "eq", value: "pending" }] },
    meta: { select: SELECT },
  });

  const statusFilter = filters?.find((f) => "field" in f && f.field === "status") as any;
  const activeKey = statusFilter ? statusFilter.value : "all";

  const applyFilter = (key: string) => {
    const next: CrudFilters = key === "all" ? [] : [{ field: "status", operator: "eq", value: key }];
    setFilters(next, "replace");
  };

  const decide = async (id: string, decision: "approve" | "reject") => {
    const reason = (notes[id] ?? "").trim();
    if (decision === "reject" && !reason) {
      message.warning("Enter a reason before declining.");
      return;
    }
    setBusy(id);
    try {
      const { data, error } = await supabaseClient.functions.invoke("admin-decide-refund", {
        body: { request_id: id, decision, notes: reason || undefined },
      });
      if (error) throw error;
      if ((data as any)?.error) throw new Error((data as any).error);
      message.success(
        (data as any)?.message ||
          (decision === "approve"
            ? "Refund approved — payment sent to the buyer's bank."
            : "Refund request declined."),
      );
      setNotes((n) => ({ ...n, [id]: "" }));
      tableQueryResult?.refetch();
    } catch (e: any) {
      message.error(String(e?.context?.error || e?.message || "Could not complete that."));
    } finally {
      setBusy(null);
    }
  };

  const err = (tableQueryResult as any)?.error;
  if (err) {
    return (
      <Alert
        type="error"
        showIcon
        message="Could not load refund requests"
        description={`${err?.message ?? err}. Have you run refund_requests.sql?`}
      />
    );
  }

  return (
    <List title="Refund requests">
      <Paragraph type="secondary" style={{ marginTop: 0 }}>
        Buyer-requested refunds await approval here. Approving pays the buyer's <b>verified bank
        account</b> via Flutterwave and cannot be undone. Automated refunds — delivery failures,
        expired pickups and dispute outcomes — are processed immediately and do not appear here.
      </Paragraph>

      <Space style={{ marginBottom: 16 }}>
        <Radio.Group
          value={activeKey}
          onChange={(e) => applyFilter(e.target.value)}
          optionType="button"
          buttonStyle="solid"
        >
          <Radio.Button value="pending">Pending</Radio.Button>
          <Radio.Button value="approved">Approved</Radio.Button>
          <Radio.Button value="rejected">Declined</Radio.Button>
          <Radio.Button value="all">All</Radio.Button>
        </Radio.Group>
      </Space>

      <Table {...tableProps} rowKey="id" size="middle">
        <Table.Column
          dataIndex="created_at"
          title="Requested"
          render={(v) => (v ? <DateField value={v} format="YYYY-MM-DD HH:mm" /> : "—")}
        />
        <Table.Column
          title="Buyer"
          render={(_, r: { buyer?: { name?: string; email?: string } }) =>
            r.buyer?.name ?? r.buyer?.email ?? "—"
          }
        />
        <Table.Column
          dataIndex="amount"
          title="Amount"
          align="right"
          render={(v) => <Text strong>{naira(v)}</Text>}
        />
        <Table.Column dataIndex="reason" title="Reason" render={(v: string) => v ?? "—"} />
        <Table.Column
          dataIndex="status"
          title="Status"
          render={(v: string) => <Tag color={statusColour(v)}>{v}</Tag>}
        />
        <Table.Column
          title="Decision"
          width={280}
          render={(_, r: { id: string; status: string; admin_notes?: string }) =>
            r.status !== "pending" ? (
              <Text type="secondary">{r.admin_notes || "—"}</Text>
            ) : (
              <Space direction="vertical" size={6} style={{ width: "100%" }}>
                <Input
                  size="small"
                  placeholder="Note (required to decline)"
                  value={notes[r.id] ?? ""}
                  onChange={(e) => setNotes((n) => ({ ...n, [r.id]: e.target.value }))}
                />
                <Space>
                  <Popconfirm
                    title="Approve this refund?"
                    description="The buyer's bank account will be paid now. This cannot be undone."
                    okText="Approve"
                    onConfirm={() => decide(r.id, "approve")}
                  >
                    <Button
                      type="primary"
                      size="small"
                      icon={<CheckOutlined />}
                      loading={busy === r.id}
                      disabled={busy !== null}
                    >
                      Approve
                    </Button>
                  </Popconfirm>
                  <Popconfirm
                    title="Decline this refund?"
                    description="No money moves. The order returns to paid."
                    okText="Decline"
                    okButtonProps={{ danger: true }}
                    onConfirm={() => decide(r.id, "reject")}
                  >
                    <Button
                      danger
                      size="small"
                      icon={<CloseOutlined />}
                      loading={busy === r.id}
                      disabled={busy !== null}
                    >
                      Decline
                    </Button>
                  </Popconfirm>
                </Space>
              </Space>
            )
          }
        />
      </Table>
    </List>
  );
};

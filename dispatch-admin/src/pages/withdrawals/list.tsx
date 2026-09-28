import { useState } from "react";
import { List, useTable, DateField } from "@refinedev/antd";
import { Table, Tag, Radio, Space, Typography, Button, Popconfirm, Input, App } from "antd";
import { SyncOutlined } from "@ant-design/icons";
import type { CrudFilters } from "@refinedev/core";
import { naira, statusColor } from "../../format";
import { supabaseClient } from "../../supabaseClient";
import { fnError } from "../../fnError";

const { Text } = Typography;

const WITHDRAWAL_SELECT = "*, user:users(name,email,role)";

// Only these need attention; the rest are terminal history.
const NEEDS_ATTENTION = ["pending_approval", "pending", "processing"];

const maskAccount = (acct?: string) =>
  acct && acct.length >= 4 ? `••••${acct.slice(-4)}` : (acct ?? "—");

export const WithdrawalList = () => {
  const { message } = App.useApp();
  const [reconciling, setReconciling] = useState<string | null>(null);
  const { tableProps, setFilters, filters, tableQueryResult } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "created_at", order: "desc" }] },
    filters: { initial: [{ field: "status", operator: "in", value: NEEDS_ATTENTION }] },
    meta: { select: WITHDRAWAL_SELECT },
  });

  const [approvalNote, setApprovalNote] = useState<Record<string, string>>({});

  const decide = async (id: string, decision: "approve" | "reject") => {
    const note = (approvalNote[id] ?? "").trim();
    if (decision === "reject" && !note) {
      message.warning("Enter a reason before declining a payout.");
      return;
    }
    setReconciling(id);
    try {
      const { data, error } = await supabaseClient.functions.invoke("admin-approve-withdrawal", {
        body: { withdrawal_id: id, decision, notes: note || undefined },
      });
      if (error) throw error;
      if ((data as any)?.error) throw new Error((data as any).error);
      message.success(
        (data as any)?.message ||
          (decision === "approve"
            ? "Payout approved — transfer sent to the bank."
            : "Payout declined — the amount is back in the vendor's wallet."),
      );
      setApprovalNote((n) => ({ ...n, [id]: "" }));
      tableQueryResult?.refetch();
    } catch (e: any) {
      message.error(await fnError(e, "Could not complete that."));
    } finally {
      setReconciling(null);
    }
  };

  const reconcile = async (id: string) => {
    setReconciling(id);
    try {
      const { data, error } = await supabaseClient.functions.invoke("admin-reconcile-withdrawal", {
        body: { withdrawal_id: id },
      });
      if (error) throw error;
      if ((data as any)?.error) throw new Error((data as any).error);
      const state = (data as any)?.state;
      if (state === "success") message.success("Confirmed sent — marked success.");
      else if (state === "failed") message.warning("Transfer failed — money returned to the user's wallet.");
      else message.info((data as any)?.message ?? "Still processing at Flutterwave.");
      tableQueryResult?.refetch();
    } catch (e: any) {
      message.error(await fnError(e, "Reconcile failed."));
    } finally {
      setReconciling(null);
    }
  };

  const statusFilter = filters?.find((f) => "field" in f && f.field === "status") as any;
  const activeKey = !statusFilter
    ? "all"
    : statusFilter.operator === "in"
    ? "attention"
    : statusFilter.value;

  const applyFilter = (key: string) => {
    const next: CrudFilters =
      key === "all"
        ? []
        : key === "attention"
        ? [{ field: "status", operator: "in", value: NEEDS_ATTENTION }]
        : [{ field: "status", operator: "eq", value: key }];
    setFilters(next, "replace");
  };

  return (
    <List title="Withdrawals">
      <Space style={{ marginBottom: 16 }}>
        <Radio.Group
          value={activeKey}
          onChange={(e) => applyFilter(e.target.value)}
          optionType="button"
          buttonStyle="solid"
        >
          <Radio.Button value="attention">Needs attention</Radio.Button>
          <Radio.Button value="pending_approval">Awaiting approval</Radio.Button>
          <Radio.Button value="processing">Processing</Radio.Button>
          <Radio.Button value="pending">Pending</Radio.Button>
          <Radio.Button value="success">Success</Radio.Button>
          <Radio.Button value="failed">Failed</Radio.Button>
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
          title="User"
          render={(_, r: { user?: { name?: string; role?: string } }) => (
            <Space direction="vertical" size={0}>
              <span>{r.user?.name ?? "—"}</span>
              {r.user?.role && (
                <Tag color={r.user.role === "vendor" ? "geekblue" : "default"}>{r.user.role}</Tag>
              )}
            </Space>
          )}
        />
        <Table.Column
          dataIndex="amount"
          title="Amount"
          align="right"
          render={(v) => <Text strong>{naira(v)}</Text>}
        />
        <Table.Column
          title="Bank"
          render={(_, r: { bank_name?: string; account_number?: string; account_name?: string }) => (
            <Space direction="vertical" size={0}>
              <span>{r.bank_name ?? "—"}</span>
              <Text type="secondary" style={{ fontFamily: "monospace" }}>
                {maskAccount(r.account_number)}
              </Text>
            </Space>
          )}
        />
        <Table.Column
          dataIndex="status"
          title="Status"
          render={(v: string) => <Tag color={statusColor(v)}>{v}</Tag>}
        />
        <Table.Column
          dataIndex="failure_reason"
          title="Failure reason"
          render={(v: string) => (v ? <Text type="danger">{v}</Text> : "—")}
        />
        <Table.Column
          title="Actions"
          width={260}
          render={(_, r: { id: string; status: string }) =>
            r.status === "pending_approval" ? (
              <Space direction="vertical" size={6} style={{ width: "100%" }}>
                <Input
                  size="small"
                  placeholder="Note (required to decline)"
                  value={approvalNote[r.id] ?? ""}
                  onChange={(e) => setApprovalNote((n) => ({ ...n, [r.id]: e.target.value }))}
                />
                <Space>
                  <Popconfirm
                    title="Approve this payout?"
                    description="The transfer is sent to the vendor's bank now. This cannot be undone."
                    okText="Approve"
                    onConfirm={() => decide(r.id, "approve")}
                  >
                    <Button type="primary" size="small" loading={reconciling === r.id} disabled={reconciling !== null}>
                      Approve
                    </Button>
                  </Popconfirm>
                  <Popconfirm
                    title="Decline this payout?"
                    description="No money leaves; the amount returns to the vendor's wallet."
                    okText="Decline"
                    okButtonProps={{ danger: true }}
                    onConfirm={() => decide(r.id, "reject")}
                  >
                    <Button danger size="small" loading={reconciling === r.id} disabled={reconciling !== null}>
                      Decline
                    </Button>
                  </Popconfirm>
                </Space>
              </Space>
            ) : r.status === "processing" ? (
              <Popconfirm
                title="Reconcile with Flutterwave?"
                description="Checks the transfer's real status and finalizes it (marks sent, or returns the money to the wallet if it failed). Safe — never double-pays."
                okText="Reconcile"
                onConfirm={() => reconcile(r.id)}
              >
                <Button size="small" icon={<SyncOutlined />} loading={reconciling === r.id}>
                  Reconcile
                </Button>
              </Popconfirm>
            ) : (
              "—"
            )
          }
        />
      </Table>
    </List>
  );
};

import { useState } from "react";
import { List, useTable, DateField } from "@refinedev/antd";
import { Table, Tag, Radio, Space, Typography, Button, Popconfirm, App } from "antd";
import { SyncOutlined } from "@ant-design/icons";
import type { CrudFilters } from "@refinedev/core";
import { naira, statusColor } from "../../format";
import { supabaseClient } from "../../supabaseClient";

const { Text } = Typography;

const WITHDRAWAL_SELECT = "*, user:users(name,email,role)";

// Only these need attention; the rest are terminal history.
const NEEDS_ATTENTION = ["pending", "processing"];

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
      message.error(String(e?.context?.error || e?.message || "Reconcile failed."));
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
          render={(_, r: { id: string; status: string }) =>
            r.status === "processing" ? (
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

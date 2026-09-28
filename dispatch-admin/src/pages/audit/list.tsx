import { List, useTable, DateField } from "@refinedev/antd";
import { Table, Tag, Typography, Radio, Space, Alert } from "antd";
import type { CrudFilters } from "@refinedev/core";

const { Text } = Typography;

const AUDIT_SELECT = "*, admin:users(name,email)";

// Group the action namespace into the filters an operator actually thinks in.
const GROUPS: Record<string, string[]> = {
  money: ["wallet.credit", "wallet.debit", "order.refund", "order.release_escrow", "withdrawal.reconcile"],
  disputes: [
    "dispute.approve_refund",
    "dispute.approve_refund_return",
    "dispute.verify_return",
    "dispute.deny_refund",
  ],
  settings: ["setting.update"],
};

const actionColor = (a: string) => {
  if (a.startsWith("wallet.") || a.startsWith("order.")) return "gold";
  if (a.startsWith("dispute.")) return "blue";
  if (a.startsWith("withdrawal.")) return "purple";
  if (a.startsWith("setting.")) return "default";
  return "default";
};

export const AuditList = () => {
  const { tableProps, setFilters, filters, tableQueryResult } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "created_at", order: "desc" }] },
    meta: { select: AUDIT_SELECT },
  });

  const actionFilter = filters?.find((f) => "field" in f && f.field === "action") as any;
  const activeKey = !actionFilter
    ? "all"
    : (Object.keys(GROUPS).find(
        (g) => JSON.stringify(GROUPS[g]) === JSON.stringify(actionFilter.value),
      ) ?? "all");

  const applyFilter = (key: string) => {
    const next: CrudFilters =
      key === "all" ? [] : [{ field: "action", operator: "in", value: GROUPS[key] }];
    setFilters(next, "replace");
  };

  // The table only exists after admin_audit_log.sql has been run.
  const err = (tableQueryResult as any)?.error;
  if (err) {
    return (
      <Alert
        type="error"
        showIcon
        message="Could not load the audit log"
        description={`${err?.message ?? err}. Have you run admin_audit_log.sql?`}
      />
    );
  }

  return (
    <List title="Audit log">
      <Space style={{ marginBottom: 16 }}>
        <Radio.Group
          value={activeKey}
          onChange={(e) => applyFilter(e.target.value)}
          optionType="button"
          buttonStyle="solid"
        >
          <Radio.Button value="all">All</Radio.Button>
          <Radio.Button value="money">Money</Radio.Button>
          <Radio.Button value="disputes">Disputes</Radio.Button>
          <Radio.Button value="settings">Settings</Radio.Button>
        </Radio.Group>
      </Space>

      <Table {...tableProps} rowKey="id" size="middle">
        <Table.Column
          dataIndex="created_at"
          title="When"
          render={(v) => (v ? <DateField value={v} format="YYYY-MM-DD HH:mm" /> : "—")}
        />
        <Table.Column
          title="Admin"
          render={(_, r: { admin?: { name?: string; email?: string } }) =>
            r.admin?.name ?? r.admin?.email ?? "—"
          }
        />
        <Table.Column
          dataIndex="action"
          title="Action"
          render={(v: string) => <Tag color={actionColor(v)}>{v}</Tag>}
        />
        <Table.Column
          dataIndex="summary"
          title="What happened"
          render={(v: string) => v ?? "—"}
        />
        <Table.Column
          title="Target"
          render={(_, r: { target_type?: string; target_id?: string }) =>
            r.target_id ? (
              <Space direction="vertical" size={0}>
                <Text type="secondary">{r.target_type}</Text>
                <Text style={{ fontFamily: "monospace" }} copyable={{ text: r.target_id }}>
                  {r.target_id.length > 12 ? `${r.target_id.slice(0, 8)}…` : r.target_id}
                </Text>
              </Space>
            ) : (
              "—"
            )
          }
        />
      </Table>
    </List>
  );
};

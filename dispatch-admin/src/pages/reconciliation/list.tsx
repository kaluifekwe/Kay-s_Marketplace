import { List, useTable, DateField } from "@refinedev/antd";
import { Table, Tag, Radio, Space, Typography, Alert, Button, App } from "antd";
import { ReloadOutlined } from "@ant-design/icons";
import { useState } from "react";
import type { CrudFilters } from "@refinedev/core";
import { naira } from "../../format";
import { supabaseClient } from "../../supabaseClient";
import { fnError } from "../../fnError";

const { Text, Paragraph } = Typography;

// How long an open exception has been outstanding — the "ageing" the finance
// controls call for. Anything past a day wants a human.
const ageOf = (iso?: string) => {
  if (!iso) return { label: "—", overdue: false };
  const h = (Date.now() - new Date(iso).getTime()) / 3_600_000;
  if (h < 1) return { label: "<1h", overdue: false };
  if (h < 24) return { label: `${Math.floor(h)}h`, overdue: false };
  return { label: `${Math.floor(h / 24)}d`, overdue: true };
};

const KIND_LABEL: Record<string, string> = {
  payout_stuck: "Payout stuck in flight",
  payout_reversal_failed: "Reversal failed — money owed back",
  payout_no_reference: "Payout has no provider reference",
  collection_not_fulfilled: "Paid but no order created",
  collection_unknown_reference: "Payment with no matching intent",
};

// A customer who paid and received nothing outranks everything else here.
const CRITICAL = new Set(["collection_not_fulfilled", "payout_reversal_failed"]);

export const ReconciliationList = () => {
  const { message } = App.useApp();
  const [running, setRunning] = useState(false);

  const { tableProps, setFilters, filters, tableQueryResult } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "first_seen_at", order: "asc" }] },
    filters: { initial: [{ field: "status", operator: "eq", value: "open" }] },
  });

  const statusFilter = filters?.find((f) => "field" in f && f.field === "status") as any;
  const activeKey = statusFilter ? statusFilter.value : "all";
  const applyFilter = (key: string) => {
    const next: CrudFilters = key === "all" ? [] : [{ field: "status", operator: "eq", value: key }];
    setFilters(next, "replace");
  };

  const runNow = async () => {
    setRunning(true);
    try {
      // Run both directions, so "Run now" means what the page describes.
      const [payouts, collections] = await Promise.all([
        supabaseClient.functions.invoke("reconcile-payouts", { body: {} }),
        supabaseClient.functions.invoke("reconcile-collections", { body: {} }),
      ]);
      const p = payouts.data as any;
      const c = collections.data as any;
      if (payouts.error && collections.error) throw payouts.error;

      const parts: string[] = [];
      if (p && !payouts.error) {
        parts.push(
          `payouts: checked ${p.checked ?? 0}, settled ${p.settled ?? 0}, reversed ${p.reversed ?? 0}`,
        );
      } else {
        parts.push("payouts: failed");
      }
      if (c && !collections.error) {
        parts.push(
          `collections: scanned ${c.scanned ?? 0}, unfulfilled ${c.unpaid_orders ?? 0}`,
        );
      } else {
        parts.push("collections: failed");
      }
      message.success(parts.join(" · "));
      tableQueryResult?.refetch();
    } catch (e: any) {
      message.error(await fnError(e, "Reconciliation failed."));
    } finally {
      setRunning(false);
    }
  };

  const err = (tableQueryResult as any)?.error;
  if (err) {
    return (
      <Alert
        type="error"
        showIcon
        message="Could not load reconciliation exceptions"
        description={`${err?.message ?? err}. Have you run reconciliation.sql?`}
      />
    );
  }

  return (
    <List
      title="Reconciliation"
      headerButtons={
        <Button icon={<ReloadOutlined />} onClick={runNow} loading={running}>
          Run now
        </Button>
      }
    >
      <Paragraph type="secondary" style={{ marginTop: 0 }}>
        Payouts are reconciled against Flutterwave every 30 minutes, and collections hourly. Most
        payout mismatches are a missed webhook and resolve themselves — settled or reversed. What
        lands here is what the jobs could <b>not</b> resolve, and it ages until someone deals with it.
        Neither job re-sends a transfer or creates an order, so they cannot double-pay or
        double-fulfil. Items marked <b>customer affected</b> mean someone paid and has nothing to
        show for it — deal with those first.
      </Paragraph>

      <Space style={{ marginBottom: 16 }}>
        <Radio.Group
          value={activeKey}
          onChange={(e) => applyFilter(e.target.value)}
          optionType="button"
          buttonStyle="solid"
        >
          <Radio.Button value="open">Open</Radio.Button>
          <Radio.Button value="resolved">Resolved</Radio.Button>
          <Radio.Button value="all">All</Radio.Button>
        </Radio.Group>
      </Space>

      <Table {...tableProps} rowKey="id" size="middle">
        <Table.Column
          dataIndex="first_seen_at"
          title="Age"
          render={(v: string) => {
            const a = ageOf(v);
            return <Tag color={a.overdue ? "red" : "default"}>{a.label}</Tag>;
          }}
        />
        <Table.Column
          dataIndex="kind"
          title="Problem"
          render={(v: string) => (
            <Space direction="vertical" size={0}>
              <Text strong>{KIND_LABEL[v] ?? v}</Text>
              {CRITICAL.has(v) && <Tag color="red">customer affected</Tag>}
            </Space>
          )}
        />
        <Table.Column
          dataIndex="amount"
          title="Amount"
          align="right"
          render={(v) => (v != null ? naira(v) : "—")}
        />
        <Table.Column
          title="Our state / provider"
          render={(_, r: { our_state?: string; provider_state?: string }) => (
            <Space direction="vertical" size={0}>
              <Text>{r.our_state ?? "—"}</Text>
              <Text type="secondary">provider: {r.provider_state ?? "unknown"}</Text>
            </Space>
          )}
        />
        <Table.Column dataIndex="details" title="Details" render={(v: string) => v ?? "—"} />
        <Table.Column
          dataIndex="last_seen_at"
          title="Last checked"
          render={(v) => (v ? <DateField value={v} format="YYYY-MM-DD HH:mm" /> : "—")}
        />
        <Table.Column
          dataIndex="status"
          title="Status"
          render={(v: string) => <Tag color={v === "open" ? "orange" : "green"}>{v}</Tag>}
        />
      </Table>
    </List>
  );
};

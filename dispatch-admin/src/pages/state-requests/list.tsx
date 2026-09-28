import { useState } from "react";
import { List, useTable, DateField } from "@refinedev/antd";
import { Table, Tag, Radio, Space, Typography, Button, Popconfirm, Input, Alert, App } from "antd";
import { CheckOutlined, CloseOutlined } from "@ant-design/icons";
import type { CrudFilters } from "@refinedev/core";
import { supabaseClient } from "../../supabaseClient";

const { Text, Paragraph } = Typography;

// Two FKs point at users (user_id and reviewed_by), so the requester embed must
// name the constraint explicitly or PostgREST cannot tell them apart.
const SELECT =
  "*, requester:users!state_change_requests_user_id_fkey(name,email,role)";

const statusColour = (s: string) =>
  s === "pending" ? "orange" : s === "approved" ? "green" : "red";

type Row = {
  id: string;
  user_id: string;
  current_state: string | null;
  requested_state: string;
  reason: string;
  status: string;
  admin_note?: string;
  requester?: { name?: string; email?: string; role?: string };
};

export const StateRequestList = () => {
  const { message } = App.useApp();
  const [busy, setBusy] = useState<string | null>(null);
  const [notes, setNotes] = useState<Record<string, string>>({});

  const { tableProps, setFilters, filters, tableQueryResult } = useTable({
    syncWithLocation: true,
    sorters: { initial: [{ field: "created_at", order: "asc" }] },
    filters: { initial: [{ field: "status", operator: "eq", value: "pending" }] },
    meta: { select: SELECT },
  });

  const statusFilter = filters?.find((f) => "field" in f && f.field === "status") as any;
  const activeKey = statusFilter ? statusFilter.value : "all";

  const applyFilter = (key: string) => {
    const next: CrudFilters = key === "all" ? [] : [{ field: "status", operator: "eq", value: key }];
    setFilters(next, "replace");
  };

  const decide = async (r: Row, decision: "approve" | "reject") => {
    setBusy(r.id);
    try {
      const {
        data: { user },
      } = await supabaseClient.auth.getUser();
      const adminId = user?.id;

      // On approval, move the requesting user to their new state first, then
      // stamp the request. Mirrors the mobile admin screen's behaviour.
      if (decision === "approve") {
        const { error: uErr } = await supabaseClient
          .from("users")
          .update({ state: r.requested_state })
          .eq("id", r.user_id);
        if (uErr) throw uErr;
      }

      const note = (notes[r.id] ?? "").trim();
      const { error } = await supabaseClient
        .from("state_change_requests")
        .update({
          status: decision === "approve" ? "approved" : "rejected",
          reviewed_by: adminId,
          reviewed_at: new Date().toISOString(),
          ...(note ? { admin_note: note } : {}),
        })
        .eq("id", r.id);
      if (error) throw error;

      message.success(
        decision === "approve"
          ? "Approved. The user has been moved to the new state."
          : "Request rejected.",
      );
      setNotes((n) => ({ ...n, [r.id]: "" }));
      tableQueryResult?.refetch();
    } catch (e: any) {
      message.error(e?.message ?? "Could not complete that.");
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
        message="Could not load state change requests"
        description={`${err?.message ?? err}. If this table is missing, run state_lock_change_requests.sql.`}
      />
    );
  }

  return (
    <List title="State change requests">
      <Paragraph type="secondary" style={{ marginTop: 0 }}>
        Buyers and vendors ask to move to a different state here. Approving updates
        the person's state right away, so they start seeing that state's marketplace
        and vendors. This is the same queue as the admin screen in the app.
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
          <Radio.Button value="rejected">Rejected</Radio.Button>
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
          title="Person"
          render={(_, r: Row) =>
            r.requester ? (
              <Space direction="vertical" size={0}>
                <Text strong>{r.requester.name ?? r.requester.email ?? "—"}</Text>
                <Text type="secondary" style={{ fontSize: 12 }}>
                  {r.requester.role ?? ""}
                  {r.requester.email ? ` · ${r.requester.email}` : ""}
                </Text>
              </Space>
            ) : (
              "—"
            )
          }
        />
        <Table.Column
          title="Move"
          render={(_, r: Row) => (
            <Text strong style={{ color: "#1b8a3a" }}>
              {(r.current_state ?? "Not set") + " → " + r.requested_state}
            </Text>
          )}
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
          render={(_, r: Row) =>
            r.status !== "pending" ? (
              <Text type="secondary">{r.admin_note || "—"}</Text>
            ) : (
              <Space direction="vertical" size={6} style={{ width: "100%" }}>
                <Input
                  size="small"
                  placeholder="Note (optional)"
                  value={notes[r.id] ?? ""}
                  onChange={(e) => setNotes((n) => ({ ...n, [r.id]: e.target.value }))}
                />
                <Space>
                  <Popconfirm
                    title="Approve this request?"
                    description="The person will be moved to the requested state now."
                    okText="Approve"
                    onConfirm={() => decide(r, "approve")}
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
                    title="Reject this request?"
                    description="Nothing changes for the person. They stay in their current state."
                    okText="Reject"
                    okButtonProps={{ danger: true }}
                    onConfirm={() => decide(r, "reject")}
                  >
                    <Button
                      danger
                      size="small"
                      icon={<CloseOutlined />}
                      loading={busy === r.id}
                      disabled={busy !== null}
                    >
                      Reject
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

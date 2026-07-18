import { useState } from "react";
import { Show } from "@refinedev/antd";
import { useShow } from "@refinedev/core";
import {
  Typography,
  Tag,
  Descriptions,
  Card,
  Input,
  Button,
  Space,
  Popconfirm,
  Alert,
  App,
} from "antd";
import { CheckCircleOutlined, CloseCircleOutlined } from "@ant-design/icons";
import { statusColor } from "../../format";
import { supabaseClient } from "../../supabaseClient";

const { Title, Text, Paragraph } = Typography;

const DISPUTE_SHOW_SELECT =
  "*, buyer:users!disputes_buyer_id_fkey(name,email), vendor:users!disputes_vendor_id_fkey(name,email)";

// Admin may act only once the negotiation-first flow has handed the dispute over.
const ACTIONABLE_STATUSES = ["awaiting_admin_decision", "escalated", "return_submitted"];

function evidenceUrls(raw: unknown): string[] {
  if (!raw) return [];
  if (Array.isArray(raw)) return raw as string[];
  try {
    const parsed = JSON.parse(String(raw));
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

export const DisputeShow = () => {
  const { message } = App.useApp();
  const { queryResult } = useShow({ meta: { select: DISPUTE_SHOW_SELECT } });
  const record = queryResult?.data?.data as Record<string, any> | undefined;

  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState<null | "approve_refund" | "deny_refund">(null);

  const actionable = record && ACTIONABLE_STATUSES.includes(record.status);

  const resolve = async (decision: "approve_refund" | "deny_refund") => {
    if (!record) return;
    if (decision === "deny_refund" && !notes.trim()) {
      message.warning("Enter a reason before denying the refund.");
      return;
    }
    setBusy(decision);
    try {
      const { data, error } = await supabaseClient.functions.invoke("admin-resolve-dispute", {
        body: { dispute_id: record.id, decision, notes: notes.trim() || undefined },
      });
      if (error) throw error;
      if ((data as any)?.error) throw new Error((data as any).error);
      message.success(
        decision === "approve_refund"
          ? "Refund approved — buyer refunded to wallet."
          : "Refund denied — vendor payout released.",
      );
      setNotes("");
      queryResult?.refetch();
    } catch (e: any) {
      // functions.invoke wraps non-2xx bodies in a FunctionsHttpError; surface the
      // server's message where we can.
      const msg =
        e?.context?.error || e?.message || "Could not resolve the dispute. Please try again.";
      message.error(String(msg));
    } finally {
      setBusy(null);
    }
  };

  const vendorEvidence = evidenceUrls(record?.vendor_evidence_urls);
  const buyerEvidence = evidenceUrls(record?.buyer_evidence_urls ?? record?.evidence_urls);

  return (
    <Show isLoading={queryResult?.isLoading} title="Dispute">
      <Descriptions bordered column={1} size="middle">
        <Descriptions.Item label="Dispute ID">
          <Text copyable style={{ fontFamily: "monospace" }}>{record?.id ?? "—"}</Text>
        </Descriptions.Item>
        <Descriptions.Item label="Order ID">
          <Text copyable style={{ fontFamily: "monospace" }}>{record?.order_id ?? "—"}</Text>
        </Descriptions.Item>
        <Descriptions.Item label="Status">
          <Tag color={statusColor(record?.status)}>{record?.status ?? "—"}</Tag>
        </Descriptions.Item>
        <Descriptions.Item label="Buyer">
          {record?.buyer?.name ?? "—"}
          {record?.buyer?.email ? ` (${record.buyer.email})` : ""}
        </Descriptions.Item>
        <Descriptions.Item label="Vendor">
          {record?.vendor?.name ?? "—"}
          {record?.vendor?.email ? ` (${record.vendor.email})` : ""}
        </Descriptions.Item>
        <Descriptions.Item label="Issue type">{record?.issue_type ?? "—"}</Descriptions.Item>
        <Descriptions.Item label="Buyer reason">{record?.reason ?? "—"}</Descriptions.Item>
        {buyerEvidence.length > 0 && (
          <Descriptions.Item label="Buyer evidence">
            <Space wrap>
              {buyerEvidence.map((u, i) => (
                <a key={i} href={u} target="_blank" rel="noreferrer">
                  Photo {i + 1}
                </a>
              ))}
            </Space>
          </Descriptions.Item>
        )}
        <Descriptions.Item label="Vendor response">
          {record?.vendor_response ?? "—"}
        </Descriptions.Item>
        {vendorEvidence.length > 0 && (
          <Descriptions.Item label="Vendor evidence">
            <Space wrap>
              {vendorEvidence.map((u, i) => (
                <a key={i} href={u} target="_blank" rel="noreferrer">
                  Photo {i + 1}
                </a>
              ))}
            </Space>
          </Descriptions.Item>
        )}
        <Descriptions.Item label="Payout hold released">
          {record?.payout_hold_released ? "Yes" : "No"}
        </Descriptions.Item>
        {record?.admin_decision && (
          <Descriptions.Item label="Admin decision">
            <Tag color={record.admin_decision === "refund_approved" ? "green" : "red"}>
              {record.admin_decision}
            </Tag>
            {record?.admin_notes ? ` — ${record.admin_notes}` : ""}
          </Descriptions.Item>
        )}
        <Descriptions.Item label="Opened">{record?.created_at ?? "—"}</Descriptions.Item>
      </Descriptions>

      {actionable ? (
        <Card
          style={{ marginTop: 24, borderTop: "3px solid #1b8a3a" }}
          title="Resolve dispute"
        >
          <Paragraph type="secondary" style={{ marginTop: 0 }}>
            <b>Approve refund</b> pays the buyer back (to wallet; credit-funded orders
            refund to credit automatically), claws back the vendor if already paid, and
            releases the payout hold. <b>Deny refund</b> moves no money, gives the buyer a
            strike (auto-flag at 3), and releases the held payout to the vendor. Both are
            final.
          </Paragraph>
          <Input.TextArea
            rows={3}
            placeholder="Notes / reason (required to deny, optional to approve)"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            style={{ marginBottom: 16 }}
          />
          <Space>
            <Popconfirm
              title="Approve refund?"
              description="The buyer will be refunded now. This cannot be undone."
              okText="Approve refund"
              okButtonProps={{ danger: false }}
              onConfirm={() => resolve("approve_refund")}
            >
              <Button
                type="primary"
                icon={<CheckCircleOutlined />}
                loading={busy === "approve_refund"}
                disabled={busy !== null}
              >
                Approve refund
              </Button>
            </Popconfirm>
            <Popconfirm
              title="Deny refund?"
              description="No money moves; the buyer gets a strike. This cannot be undone."
              okText="Deny refund"
              okButtonProps={{ danger: true }}
              onConfirm={() => resolve("deny_refund")}
            >
              <Button
                danger
                icon={<CloseCircleOutlined />}
                loading={busy === "deny_refund"}
                disabled={busy !== null}
              >
                Deny refund
              </Button>
            </Popconfirm>
          </Space>
        </Card>
      ) : (
        <Alert
          style={{ marginTop: 24 }}
          type="info"
          showIcon
          message="No admin action available"
          description={
            record
              ? `This dispute is "${record.status}" — admin can only act on awaiting_admin_decision, escalated, or return_submitted disputes.`
              : "Loading…"
          }
        />
      )}
    </Show>
  );
};

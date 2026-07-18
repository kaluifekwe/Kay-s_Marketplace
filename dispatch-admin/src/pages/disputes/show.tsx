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
import {
  CheckCircleOutlined,
  CloseCircleOutlined,
  RollbackOutlined,
  AuditOutlined,
} from "@ant-design/icons";
import { statusColor } from "../../format";
import { supabaseClient } from "../../supabaseClient";

const { Text, Paragraph } = Typography;

const DISPUTE_SHOW_SELECT =
  "*, buyer:users!disputes_buyer_id_fkey(name,email), vendor:users!disputes_vendor_id_fkey(name,email)";

type Decision = "approve_refund" | "approve_refund_return" | "verify_return" | "deny_refund";

// States where the admin decides the outcome (approve / require return / deny).
const DECISION_STATES = ["awaiting_admin_decision", "escalated"];

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

const fmt = (v?: string) => (v ? new Date(v).toLocaleString() : "—");

export const DisputeShow = () => {
  const { message } = App.useApp();
  const { queryResult } = useShow({ meta: { select: DISPUTE_SHOW_SELECT } });
  const record = queryResult?.data?.data as Record<string, any> | undefined;

  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState<Decision | null>(null);

  const status = record?.status as string | undefined;
  const inDecision = !!status && DECISION_STATES.includes(status);
  const inReturnReview = status === "return_submitted";

  const resolve = async (decision: Decision) => {
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
      const msgByDecision: Record<Decision, string> = {
        approve_refund: "Refund approved — buyer refunded to wallet.",
        approve_refund_return: "Approved — buyer asked to return the item within 24h.",
        verify_return: "Return verified — vendor asked to confirm receipt within 24h.",
        deny_refund: "Refund denied — vendor payout released.",
      };
      message.success((data as any)?.message || msgByDecision[decision]);
      setNotes("");
      queryResult?.refetch();
    } catch (e: any) {
      message.error(String(e?.context?.error || e?.message || "Could not resolve the dispute."));
    } finally {
      setBusy(null);
    }
  };

  const vendorEvidence = evidenceUrls(record?.vendor_evidence_urls);
  const buyerEvidence = evidenceUrls(record?.buyer_evidence_urls ?? record?.evidence_urls);
  const returnPhotos = evidenceUrls(record?.return_receipt_photos);

  const busyAny = busy !== null;

  const PhotoLinks = ({ urls }: { urls: string[] }) => (
    <Space wrap>
      {urls.map((u, i) => (
        <a key={i} href={u} target="_blank" rel="noreferrer">
          Photo {i + 1}
        </a>
      ))}
    </Space>
  );

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
          <Tag color={statusColor(status)}>{status ?? "—"}</Tag>
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
            <PhotoLinks urls={buyerEvidence} />
          </Descriptions.Item>
        )}
        <Descriptions.Item label="Vendor response">{record?.vendor_response ?? "—"}</Descriptions.Item>
        {vendorEvidence.length > 0 && (
          <Descriptions.Item label="Vendor evidence">
            <PhotoLinks urls={vendorEvidence} />
          </Descriptions.Item>
        )}
        {record?.return_required && (
          <Descriptions.Item label="Return deadline">{fmt(record?.return_deadline)}</Descriptions.Item>
        )}
        {returnPhotos.length > 0 && (
          <Descriptions.Item label="Return photos (buyer)">
            <PhotoLinks urls={returnPhotos} />
          </Descriptions.Item>
        )}
        {record?.vendor_confirm_deadline && (
          <Descriptions.Item label="Vendor confirm deadline">
            {fmt(record?.vendor_confirm_deadline)}
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

      {inDecision && (
        <Card style={{ marginTop: 24, borderTop: "3px solid #1b8a3a" }} title="Resolve dispute">
          <Paragraph type="secondary" style={{ marginTop: 0 }}>
            <b>Approve refund now</b> pays the buyer back immediately (wallet; credit-funded orders
            refund to credit), claws back the vendor if already paid, releases the hold.{" "}
            <b>Approve with return</b> requires the buyer to ship the item back first — the refund
            fires after the vendor confirms receipt. <b>Deny</b> moves no money, strikes the buyer
            (auto-flag at 3), and releases the held payout to the vendor.
          </Paragraph>
          <Input.TextArea
            rows={3}
            placeholder="Notes / reason (required to deny, optional otherwise)"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            style={{ marginBottom: 16 }}
          />
          <Space wrap>
            <Popconfirm
              title="Approve refund now?"
              description="The buyer is refunded immediately. This cannot be undone."
              okText="Approve now"
              onConfirm={() => resolve("approve_refund")}
            >
              <Button type="primary" icon={<CheckCircleOutlined />} loading={busy === "approve_refund"} disabled={busyAny}>
                Approve refund now
              </Button>
            </Popconfirm>
            <Popconfirm
              title="Approve with return?"
              description="Buyer must ship the item back within 24h; refund fires after the vendor confirms receipt."
              okText="Approve with return"
              onConfirm={() => resolve("approve_refund_return")}
            >
              <Button icon={<RollbackOutlined />} loading={busy === "approve_refund_return"} disabled={busyAny}>
                Approve with return
              </Button>
            </Popconfirm>
            <Popconfirm
              title="Deny refund?"
              description="No money moves; the buyer gets a strike. This cannot be undone."
              okText="Deny refund"
              okButtonProps={{ danger: true }}
              onConfirm={() => resolve("deny_refund")}
            >
              <Button danger icon={<CloseCircleOutlined />} loading={busy === "deny_refund"} disabled={busyAny}>
                Deny refund
              </Button>
            </Popconfirm>
          </Space>
        </Card>
      )}

      {inReturnReview && (
        <Card style={{ marginTop: 24, borderTop: "3px solid #1677ff" }} title="Review returned item">
          <Paragraph type="secondary" style={{ marginTop: 0 }}>
            The buyer submitted return photos (above). <b>Verify return</b> if they look legitimate —
            the vendor then has 24h to confirm receipt, after which the refund is processed. If the
            return looks bogus you can <b>Deny</b> (strikes the buyer) or <b>Approve refund now</b> to
            refund without waiting on the vendor.
          </Paragraph>
          <Input.TextArea
            rows={2}
            placeholder="Notes (optional; required to deny)"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            style={{ marginBottom: 16 }}
          />
          <Space wrap>
            <Popconfirm
              title="Verify the return?"
              description="Hands off to the vendor to confirm receipt within 24h."
              okText="Verify return"
              onConfirm={() => resolve("verify_return")}
            >
              <Button type="primary" icon={<AuditOutlined />} loading={busy === "verify_return"} disabled={busyAny}>
                Verify return
              </Button>
            </Popconfirm>
            <Popconfirm
              title="Approve refund now?"
              description="Refund the buyer immediately without waiting on the vendor."
              okText="Approve now"
              onConfirm={() => resolve("approve_refund")}
            >
              <Button icon={<CheckCircleOutlined />} loading={busy === "approve_refund"} disabled={busyAny}>
                Approve refund now
              </Button>
            </Popconfirm>
            <Popconfirm
              title="Deny refund?"
              description="No money moves; the buyer gets a strike."
              okText="Deny refund"
              okButtonProps={{ danger: true }}
              onConfirm={() => resolve("deny_refund")}
            >
              <Button danger icon={<CloseCircleOutlined />} loading={busy === "deny_refund"} disabled={busyAny}>
                Deny refund
              </Button>
            </Popconfirm>
          </Space>
        </Card>
      )}

      {status === "awaiting_return" && (
        <Alert
          style={{ marginTop: 24 }}
          type="warning"
          showIcon
          message="Waiting for the buyer to return the item"
          description={`Approved with return. Buyer must ship back by ${fmt(record?.return_deadline)}. No admin action needed until they submit return photos.`}
        />
      )}
      {status === "vendor_confirming" && (
        <Alert
          style={{ marginTop: 24 }}
          type="info"
          showIcon
          message="Waiting for the vendor to confirm receipt"
          description={`Return verified. Vendor must confirm by ${fmt(record?.vendor_confirm_deadline)}, after which the refund auto-processes. If the vendor disputes receipt, it returns here for a final decision.`}
        />
      )}
      {!inDecision && !inReturnReview && status !== "awaiting_return" && status !== "vendor_confirming" && (
        <Alert
          style={{ marginTop: 24 }}
          type="info"
          showIcon
          message="No admin action available"
          description={
            record ? `This dispute is "${status}".` : "Loading…"
          }
        />
      )}
    </Show>
  );
};

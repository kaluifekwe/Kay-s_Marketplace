import { Show } from "@refinedev/antd";
import { useShow } from "@refinedev/core";
import { Typography, Tag, Descriptions } from "antd";
import { statusColor } from "../../format";

const { Title } = Typography;

export const DisputeShow = () => {
  const { queryResult } = useShow();
  const record = queryResult?.data?.data;

  return (
    <Show isLoading={queryResult?.isLoading} title="Dispute">
      <Descriptions bordered column={1} size="middle">
        <Descriptions.Item label="Dispute ID">
          {record?.id ?? "—"}
        </Descriptions.Item>
        <Descriptions.Item label="Order ID">
          {record?.order_id ?? "—"}
        </Descriptions.Item>
        <Descriptions.Item label="Status">
          <Tag color={statusColor(record?.status)}>{record?.status ?? "—"}</Tag>
        </Descriptions.Item>
        <Descriptions.Item label="Buyer ID">
          {record?.buyer_id ?? "—"}
        </Descriptions.Item>
        <Descriptions.Item label="Vendor ID">
          {record?.vendor_id ?? "—"}
        </Descriptions.Item>
        <Descriptions.Item label="Reason">
          {record?.reason ?? "—"}
        </Descriptions.Item>
        <Descriptions.Item label="Payout hold released">
          {record?.payout_hold_released ? "Yes" : "No"}
        </Descriptions.Item>
        <Descriptions.Item label="Opened">
          {record?.created_at ?? "—"}
        </Descriptions.Item>
      </Descriptions>
      <Title level={5} style={{ marginTop: 24, color: "#888" }}>
        Resolve actions (approve refund, deny, verify return) — routed through the
        audited edge functions — land here in Phase 2.
      </Title>
    </Show>
  );
};

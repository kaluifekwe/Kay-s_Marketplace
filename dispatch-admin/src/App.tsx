import { Authenticated, Refine } from "@refinedev/core";
import {
  ThemedLayoutV2,
  ErrorComponent,
  useNotificationProvider,
  AuthPage,
  ThemedTitleV2,
} from "@refinedev/antd";
import "@refinedev/antd/dist/reset.css";
import { dataProvider, liveProvider } from "@refinedev/supabase";
import routerBindings, {
  CatchAllNavigate,
  NavigateToResource,
  DocumentTitleHandler,
  UnsavedChangesNotifier,
} from "@refinedev/react-router-v6";
import { App as AntdApp, ConfigProvider } from "antd";
import { BrowserRouter, Outlet, Route, Routes } from "react-router-dom";
import {
  DashboardOutlined,
  ShoppingOutlined,
  TeamOutlined,
  WarningOutlined,
  BankOutlined,
  SettingOutlined,
  FileSearchOutlined,
  UndoOutlined,
  DiffOutlined,
} from "@ant-design/icons";

import { supabaseClient } from "./supabaseClient";
import { authProvider } from "./authProvider";
import { Dashboard } from "./pages/dashboard";
import { UserList, UserShow } from "./pages/users";
import { OrderList, OrderShow } from "./pages/orders";
import { DisputeList, DisputeShow } from "./pages/disputes";
import { WithdrawalList } from "./pages/withdrawals";
import { SettingsList } from "./pages/settings";
import { AuditList } from "./pages/audit";
import { RefundList } from "./pages/refunds";
import { ReconciliationList } from "./pages/reconciliation";

const BRAND = "#1b8a3a"; // Kays Market green

function App() {
  return (
    <BrowserRouter>
      <ConfigProvider theme={{ token: { colorPrimary: BRAND } }}>
        <AntdApp>
          <Refine
            dataProvider={dataProvider(supabaseClient)}
            liveProvider={liveProvider(supabaseClient)}
            authProvider={authProvider}
            routerProvider={routerBindings}
            notificationProvider={useNotificationProvider}
            resources={[
              {
                name: "dashboard",
                list: "/",
                meta: { label: "Dashboard", icon: <DashboardOutlined /> },
              },
              {
                name: "orders",
                list: "/orders",
                show: "/orders/show/:id",
                meta: { label: "Orders", icon: <ShoppingOutlined /> },
              },
              {
                name: "disputes",
                list: "/disputes",
                show: "/disputes/show/:id",
                meta: { label: "Disputes", icon: <WarningOutlined /> },
              },
              {
                name: "refund_requests",
                list: "/refunds",
                meta: { label: "Refunds", icon: <UndoOutlined /> },
              },
              {
                name: "withdrawals",
                list: "/withdrawals",
                meta: { label: "Withdrawals", icon: <BankOutlined /> },
              },
              {
                name: "reconciliation_exceptions",
                list: "/reconciliation",
                meta: { label: "Reconciliation", icon: <DiffOutlined /> },
              },
              {
                name: "users",
                list: "/users",
                show: "/users/show/:id",
                meta: { label: "Users", icon: <TeamOutlined /> },
              },
              {
                name: "admin_audit_log",
                list: "/audit",
                meta: { label: "Audit log", icon: <FileSearchOutlined /> },
              },
              {
                name: "settings",
                list: "/settings",
                meta: { label: "Settings", icon: <SettingOutlined /> },
              },
            ]}
            options={{
              syncWithLocation: true,
              warnWhenUnsavedChanges: true,
            }}
          >
            <Routes>
              <Route
                element={
                  <Authenticated
                    key="authenticated-routes"
                    fallback={<CatchAllNavigate to="/login" />}
                  >
                    <ThemedLayoutV2
                      Title={({ collapsed }) => (
                        <ThemedTitleV2
                          collapsed={collapsed}
                          text="Kays Market"
                          icon={<ShoppingOutlined />}
                        />
                      )}
                    >
                      <Outlet />
                    </ThemedLayoutV2>
                  </Authenticated>
                }
              >
                <Route index element={<Dashboard />} />
                <Route path="/orders">
                  <Route index element={<OrderList />} />
                  <Route path="show/:id" element={<OrderShow />} />
                </Route>
                <Route path="/disputes">
                  <Route index element={<DisputeList />} />
                  <Route path="show/:id" element={<DisputeShow />} />
                </Route>
                <Route path="/refunds">
                  <Route index element={<RefundList />} />
                </Route>
                <Route path="/withdrawals">
                  <Route index element={<WithdrawalList />} />
                </Route>
                <Route path="/reconciliation">
                  <Route index element={<ReconciliationList />} />
                </Route>
                <Route path="/users">
                  <Route index element={<UserList />} />
                  <Route path="show/:id" element={<UserShow />} />
                </Route>
                <Route path="/audit">
                  <Route index element={<AuditList />} />
                </Route>
                <Route path="/settings">
                  <Route index element={<SettingsList />} />
                </Route>
                <Route path="*" element={<ErrorComponent />} />
              </Route>

              <Route
                element={
                  <Authenticated key="auth-pages" fallback={<Outlet />}>
                    <NavigateToResource resource="dashboard" />
                  </Authenticated>
                }
              >
                <Route
                  path="/login"
                  element={
                    <AuthPage
                      type="login"
                      registerLink={false}
                      forgotPasswordLink={false}
                      title={
                        <ThemedTitleV2
                          collapsed={false}
                          text="Kays Market Admin"
                          icon={<ShoppingOutlined />}
                        />
                      }
                    />
                  }
                />
              </Route>
            </Routes>

            <UnsavedChangesNotifier />
            <DocumentTitleHandler />
          </Refine>
        </AntdApp>
      </ConfigProvider>
    </BrowserRouter>
  );
}

export default App;

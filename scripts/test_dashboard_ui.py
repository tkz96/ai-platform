import asyncio
from pathlib import Path

from playwright.async_api import async_playwright

ARTIFACT_DIR = Path(
    "/Users/ai-macmini/.gemini/antigravity-ide/brain/a60af437-9fa4-4660-9ce3-1f1875b680f6"
)


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context(viewport={"width": 1440, "height": 900})
        page = await context.new_page()

        print("Navigating to dashboard...")
        await page.goto("http://127.0.0.1:8888", wait_until="networkidle")

        # 1. Setup & Provision Tab
        await page.click("#tab-setup")
        await page.wait_for_timeout(500)
        await page.screenshot(path=str(ARTIFACT_DIR / "dashboard_setup.png"), full_page=True)
        print("Captured dashboard_setup.png")

        # 2. Services / Control Plane
        await page.click("#tab-services")
        await page.wait_for_timeout(500)
        await page.screenshot(path=str(ARTIFACT_DIR / "dashboard_services.png"), full_page=True)
        print("Captured dashboard_services.png")

        # 3. Nodes Tab
        await page.click("#tab-nodes")
        await page.wait_for_timeout(400)
        await page.screenshot(path=str(ARTIFACT_DIR / "dashboard_nodes.png"), full_page=True)
        print("Captured dashboard_nodes.png")

        # 4. Topology Tab
        await page.click("#tab-topology")
        await page.wait_for_timeout(400)
        await page.screenshot(path=str(ARTIFACT_DIR / "dashboard_topology.png"), full_page=True)
        print("Captured dashboard_topology.png")

        # 5. Health Matrix Tab
        await page.click("#tab-health")
        await page.wait_for_timeout(1000)
        await page.screenshot(path=str(ARTIFACT_DIR / "dashboard_health.png"), full_page=True)
        print("Captured dashboard_health.png")

        # 6. Playground Tab
        await page.click("#tab-playground")
        await page.wait_for_timeout(400)
        await page.screenshot(path=str(ARTIFACT_DIR / "dashboard_playground.png"), full_page=True)
        print("Captured dashboard_playground.png")

        # 7. Audit Modal Trigger
        await page.click("button:has-text('Audit')")
        await page.wait_for_selector("#audit-modal-title", timeout=3000)
        await page.wait_for_timeout(500)
        await page.screenshot(path=str(ARTIFACT_DIR / "dashboard_audit.png"), full_page=True)
        print("Captured dashboard_audit.png")

        await browser.close()
        print("All UI views captured successfully!")


if __name__ == "__main__":
    asyncio.run(main())

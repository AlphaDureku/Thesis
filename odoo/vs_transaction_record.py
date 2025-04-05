from odoo import models, fields, api

PAYMENT_STATE_SELECTION = [
    ('not_paid', 'Not Paid'),
    ('partial', 'Partial'),
    ('paid', 'Paid'),
    ('in_payment', 'In Payment'),
    ('reversed', 'Reversed')
]

class ShpMonthlyRecord(models.Model):
    _name = 'shp.vs_account_records'
    _description = 'Voluntary Surety'
    _rec_name = 'displayName'

    company_id = fields.Many2one(
        'res.company', string="Company",
        default=lambda self: self.env.company, required=True
    )
    currency_id = fields.Many2one(
        'res.currency', string="Currency",
        related='company_id.currency_id', readonly=True, store=True
    )

    sales_order_id = fields.Many2one('sale.order', string="Related SO")
    lender_id = fields.Many2one('shp.partners', string="Lender", ondelete='cascade', readonly=True, store=True)
    borrower_id = fields.Many2one('shp.partners', string="Borrower", ondelete='cascade', readonly=True, store=True)
    attachment = fields.Binary(string="Attachment")  # Field to store the file
    attachment_filename = fields.Char(string="Attachment Filename")  # Optional, to store the filename

    
    related_invoice_ids = fields.Many2many(
        'account.move', string="Invoices",
        compute="_compute_related_invoices", store=True, readonly=True
    )
    
    total_lent = fields.Monetary(string="Total Lent", readonly=True, store=True)
    total_invoice_paid = fields.Monetary(string="Invoice Paid Amount", compute="_compute_invoice", store=True, readonly=True)
    total_invoice_unpaid = fields.Monetary(string="Invoice Unpaid Amount", compute="_compute_invoice", store=True, readonly=True)
    
    reason = fields.Char(string="Reason", readonly=True)
    displayName = fields.Char(string='Name', readonly=True)

    invoice_date_due = fields.Date(
        string="Invoice Due Date",
        compute="_compute_invoice", store=True
    )

    payment_state = fields.Selection(
        selection=PAYMENT_STATE_SELECTION,
        compute="_compute_payment_state", store=True,
        string="Payment State", readonly=True
    )

    vs_payment_state = fields.Selection(
        selection=PAYMENT_STATE_SELECTION,
        compute="_compute_vs_payment_state", store=True,
        string="Payment State", readonly=True
    )    
    
    @api.depends('total_invoice_paid')
    def _compute_vs_payment_state(self):
        for record in self:
            if not record.total_invoice_paid:
                record.vs_payment_state = 'not_paid'
            elif record.total_invoice_paid >= record.total_lent:
                record.vs_payment_state = 'paid'
            else:
                record.vs_payment_state = 'partial'
                
        
    
    @api.depends("related_invoice_ids.amount_residual", "related_invoice_ids.invoice_date_due")
    def _compute_invoice(self):
        """Compute invoice due date, total paid, and unpaid amount"""
        for record in self:
            invoices = record.related_invoice_ids.filtered(lambda inv: inv.state != 'cancel')
            if invoices:
                first_invoice = invoices.sorted('invoice_date_due')[0]  # Get the earliest invoice
                record.invoice_date_due = first_invoice.invoice_date_due
                record.total_invoice_unpaid = sum(invoices.mapped('amount_residual'))
                record.total_invoice_paid = sum(invoices.mapped(lambda inv: inv.amount_total_signed - inv.amount_residual))
            else:
                record.invoice_date_due = False
                record.total_invoice_unpaid = 0
                record.total_invoice_paid = 0

    @api.depends('sales_order_id.invoice_ids')
    def _compute_related_invoices(self):
        """Compute related invoices from sales order, filtering out canceled ones"""
        for record in self:
            invoices = record.sales_order_id.invoice_ids.filtered(lambda inv: inv.state != 'cancel') if record.sales_order_id.exists() else []
            record.related_invoice_ids = [(6, 0, invoices.ids)]  # Assign invoice IDs

    @api.depends('related_invoice_ids.payment_state')
    def _compute_payment_state(self):
        """Compute the overall payment state based on all related invoices"""
        for record in self:
            invoices = record.related_invoice_ids
            if not invoices:
                record.payment_state = 'not_paid'
                continue

            states = set(invoices.mapped('payment_state'))

            if 'reversed' in states:
                record.payment_state = 'reversed'
            elif 'not_paid' in states:
                record.payment_state = 'not_paid'
            elif 'partial' in states:
                record.payment_state = 'partial'
            elif 'in_payment' in states:
                record.payment_state = 'in_payment'
            elif states == {'paid'}:
                record.payment_state = 'paid'
            else:
                record.payment_state = 'partial'  # Default fallback
